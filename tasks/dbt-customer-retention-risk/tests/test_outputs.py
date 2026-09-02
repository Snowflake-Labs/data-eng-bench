"""
Test verifier for dbt-customer-retention-risk task.
"""
import subprocess
import math
import json
import os
from pathlib import Path


# ============ DUAL-BACKEND INFRASTRUCTURE ============


def load_snowflake_env():
    """Load Snowflake environment variables from file if available"""
    env_file = '/tmp/snowflake_env.sh'
    if os.path.exists(env_file):
        result = subprocess.run(
            ['bash', '-c', f'source {env_file} && env'],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if '=' in line and line.startswith('SNOWFLAKE_'):
                key, _, value = line.partition('=')
                os.environ[key] = value


# Load Snowflake env vars at module import time
load_snowflake_env()


def get_private_key():
    """Load private key from base64-encoded env var"""
    import base64
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization

    private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
    if not private_key_b64:
        raise ValueError("SNOWFLAKE_PRIVATE_KEY not found")
    private_key_pem = base64.b64decode(private_key_b64)
    passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    passphrase_bytes = passphrase.encode() if passphrase else None
    p_key = serialization.load_pem_private_key(
        private_key_pem,
        password=passphrase_bytes,
        backend=default_backend()
    )
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )


def get_db_connection():
    """Create a database connection based on DB_TYPE environment variable"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        import snowflake.connector
        # Try password auth first (the eval connection uses password, not private key)
        password = os.environ.get('SNOWFLAKE_PASSWORD')
        if password:
            conn = snowflake.connector.connect(
                account=os.environ['SNOWFLAKE_ACCOUNT'],
                **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
                user=os.environ['SNOWFLAKE_USER'],
                password=password,
                database=os.environ['SNOWFLAKE_DATABASE'],
                schema='main',
                warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
                role=os.environ.get('SNOWFLAKE_ROLE', None))
            return conn, 'snowflake'
        # Fall back to private key auth
        conn = snowflake.connector.connect(
            account=os.environ['SNOWFLAKE_ACCOUNT'],
            **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
            user=os.environ['SNOWFLAKE_USER'],
            private_key=get_private_key(),
            database=os.environ['SNOWFLAKE_DATABASE'],
            schema='main',
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def execute_query(conn, db_type, query, params=None):
    """Execute a query and return results, handling differences between DuckDB and Snowflake"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        if params:
            cursor.execute(query, params)
        else:
            cursor.execute(query)
        return cursor.fetchall()
    else:
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


def get_description(conn, db_type, query):
    """Execute a query and return column description"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        cursor.execute(query)
        return cursor.description
    else:
        result = conn.execute(query)
        return result.description


# ============ HELPERS ============
def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        cwd = os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        base = os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        base = get_dbt_project_dir()
    model_path = os.path.join(base, "models/marts/customer/rpt_customer_retention_risk.sql")
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    result = run_cmd("dbt run -s rpt_customer_retention_risk")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                avg_order_value, order_frequency, return_rate,
                revenue_per_tenure, retention_risk_score,
                recency_percentile, frequency_percentile, monetary_percentile,
                risk_percentile, customer_health_index
            FROM main.rpt_customer_retention_risk
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None:
                    try:
                        if math.isinf(float(val)) or math.isnan(float(val)):
                            inf_nan_count += 1
                    except (TypeError, ValueError, OverflowError):
                        pass

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled properly")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    conn, db_type = get_db_connection()
    try:
        output_count = execute_query(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_customer_retention_risk
        """)[0][0]

        source_count = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT customer_id)
            FROM main.int_sales__orders_enriched
            WHERE customer_id IS NOT NULL
              AND status != 'CANCELLED'
        """)[0][0]

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns Exist ============

def component_4_required_columns():
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'customer_id', 'customer_type', 'acquisition_source',
            'total_orders', 'total_revenue', 'first_order_date', 'last_order_date',
            'days_since_last_order', 'customer_tenure_days',
            'total_returns', 'total_refund_amount',
            'avg_order_value', 'order_frequency', 'net_revenue', 'return_rate',
            'revenue_per_tenure', 'retention_risk_score',
            'recency_percentile', 'frequency_percentile', 'monetary_percentile',
            'risk_percentile', 'type_rank', 'type_customer_count',
            'above_type_avg_frequency', 'retention_risk_tier', 'customer_health_index'
        ]

        desc = get_description(conn, db_type, """
            SELECT * FROM main.rpt_customer_retention_risk LIMIT 1
        """)

        actual_columns = [col[0].lower() for col in desc]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Risk Score Bounds and Distribution ============

def component_5_risk_score_bounds():
    """Validate retention_risk_score is bounded 0-100 and has reasonable distribution"""
    conn, db_type = get_db_connection()
    try:
        bounds = execute_query(conn, db_type, """
            SELECT MIN(retention_risk_score), MAX(retention_risk_score)
            FROM main.rpt_customer_retention_risk
        """)[0]

        min_rs, max_rs = bounds
        if min_rs is not None:
            require(float(min_rs) >= -0.01, f"retention_risk_score has value below 0: {min_rs}")
        if max_rs is not None:
            require(float(max_rs) <= 100.01, f"retention_risk_score exceeds 100: {max_rs}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Uses PERCENT_RANK and PARTITION BY ============

def component_6_uses_window_functions():
    sql = read_model_file().lower()

    percent_rank_count = sql.count('percent_rank()')
    require(percent_rank_count >= 4,
            f"Must use PERCENT_RANK() at least 4 times for percentile calculations, found {percent_rank_count}")

    has_partition = 'partition by' in sql
    require(has_partition, "Must use PARTITION BY for customer type peer comparison metrics")

    return 1.0


# ============ COMPONENT 7: Waterfall Tier Logic and Distribution ============

def component_7_waterfall_tier_logic():
    """Validate tier classification logic, distribution, and valid values"""
    conn, db_type = get_db_connection()
    try:
        # Check valid tier values
        tier_result = execute_query(conn, db_type, """
            SELECT DISTINCT retention_risk_tier FROM main.rpt_customer_retention_risk
        """)

        valid_tiers = {'churned', 'critical', 'at_risk', 'needs_attention', 'loyal', 'stable'}
        actual_tiers = {row[0].lower() if row[0] else None for row in tier_result}
        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid tier values found: {invalid}")

        # Check tier distribution (at least 3 different tiers)
        tier_counts = execute_query(conn, db_type, """
            SELECT retention_risk_tier, COUNT(*) as cnt
            FROM main.rpt_customer_retention_risk
            GROUP BY retention_risk_tier
        """)
        tier_count_dict = {row[0].lower() if row[0] else None: row[1] for row in tier_counts}
        require(len(tier_count_dict) >= 3,
                f"Only {len(tier_count_dict)} distinct tiers - classification not working properly")

        # Validate waterfall logic on sample
        results = execute_query(conn, db_type, """
            SELECT
                customer_id,
                total_orders,
                days_since_last_order,
                order_frequency,
                return_rate,
                risk_percentile,
                retention_risk_tier
            FROM main.rpt_customer_retention_risk
            LIMIT 30
        """)

        errors = []
        for cid, total_orders, days_since, freq, ret_rate, risk_pct, actual_tier in results:
            days_since = float(days_since) if days_since is not None else 999
            freq = float(freq) if freq else 0
            ret_rate = float(ret_rate) if ret_rate else 0
            risk_pct = float(risk_pct) if risk_pct is not None else 0.5

            # Waterfall logic
            if days_since > 180 and total_orders == 1:
                expected = 'churned'
            elif risk_pct >= 0.85 and days_since > 90:
                expected = 'critical'
            elif risk_pct >= 0.70 or (days_since > 60 and ret_rate >= 0.20):
                expected = 'at_risk'
            elif risk_pct >= 0.50 and freq < 0.5:
                expected = 'needs_attention'
            elif risk_pct <= 0.20 and freq >= 1.0 and ret_rate < 0.10:
                expected = 'loyal'
            else:
                expected = 'stable'

            if actual_tier and actual_tier.lower() != expected:
                errors.append(f"Customer {cid}: tier='{actual_tier}', expected='{expected}' "
                            f"(days={days_since}, freq={freq:.2f}, ret_rate={ret_rate:.2f}, "
                            f"risk_pct={risk_pct:.2f}, orders={total_orders})")

        require(len(errors) == 0, f"Tier logic errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: Uses Reference Date Not Current Date ============

def component_8_uses_reference_date():
    """Validate model uses MAX(ordered_at) as reference, not current_date"""
    sql = read_model_file().lower()

    # Should NOT contain current_date or now() for date calculations
    has_current_date = 'current_date' in sql and 'date_diff' in sql
    has_now = 'now()' in sql and 'date_diff' in sql

    # Should contain MAX(ordered_at) or similar pattern
    has_max_ordered = 'max(ordered_at)' in sql or 'max(o.ordered_at)' in sql

    require(not has_current_date and not has_now,
            "Model should use MAX(ordered_at) as reference date, not current_date or now()")
    require(has_max_ordered,
            "Model should calculate reference date from MAX(ordered_at)")

    return 1.0


# ============ COMPONENT 9: Risk Score Formula Validation ============

def component_9_risk_score_formula():
    """Validate risk score formula matches documented calculation in instruction.md"""
    conn, db_type = get_db_connection()
    try:
        # Get medians for validation
        medians = execute_query(conn, db_type, """
            SELECT
                MEDIAN(avg_order_value) as median_aov,
                MEDIAN(order_frequency) as median_freq
            FROM main.rpt_customer_retention_risk
            WHERE avg_order_value IS NOT NULL
        """)[0]
        median_aov, median_freq = float(medians[0] or 1), float(medians[1] or 1)

        results = execute_query(conn, db_type, """
            SELECT
                customer_id,
                days_since_last_order,
                order_frequency,
                avg_order_value,
                return_rate,
                retention_risk_score
            FROM main.rpt_customer_retention_risk
            WHERE retention_risk_score IS NOT NULL
            LIMIT 20
        """)

        errors = []
        for cid, days_since, freq, aov, ret_rate, actual_score in results:
            days_since = float(days_since) if days_since is not None else 999
            freq = float(freq) if freq else 0
            aov = float(aov) if aov else 0
            ret_rate = float(ret_rate) if ret_rate else 0
            actual_score = float(actual_score)

            recency_risk = min(1, max(0, days_since / 90.0))
            frequency_risk = min(1, max(0, 1 - min(freq / median_freq, 2) / 2))
            monetary_risk = min(1, max(0, 1 - min(aov / median_aov, 2) / 2))
            return_risk = min(1, max(0, ret_rate / 0.30))

            expected = (recency_risk * 0.40 +
                       frequency_risk * 0.25 +
                       monetary_risk * 0.20 +
                       return_risk * 0.15) * 100

            if abs(actual_score - expected) > 3.0:
                errors.append(f"customer {cid}: score={actual_score:.2f}, expected={expected:.2f}")

        require(len(errors) == 0, f"Risk score formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Strict retention_risk_score Bounded 0-100 ============

def component_10_retention_risk_score_strict_bounds():
    """Verify ALL rows have retention_risk_score between 0 and 100 inclusive."""
    conn, db_type = get_db_connection()
    try:
        violations = execute_query(conn, db_type, """
            SELECT customer_id, retention_risk_score
            FROM main.rpt_customer_retention_risk
            WHERE retention_risk_score < 0 OR retention_risk_score > 100
        """)
        require(len(violations) == 0,
                f"Found {len(violations)} rows with retention_risk_score outside [0,100]: "
                f"{[(r[0], float(r[1])) for r in violations[:5]]}")

        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_customer_retention_risk
            WHERE retention_risk_score IS NULL
        """)
        require(int(null_count) == 0,
                f"Found {null_count} rows with NULL retention_risk_score")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Strict customer_health_index Bounded 0-100 ============

def component_11_customer_health_index_strict_bounds():
    """Verify ALL rows have customer_health_index between 0 and 100 inclusive."""
    conn, db_type = get_db_connection()
    try:
        violations = execute_query(conn, db_type, """
            SELECT customer_id, customer_health_index
            FROM main.rpt_customer_retention_risk
            WHERE customer_health_index < 0 OR customer_health_index > 100
        """)
        require(len(violations) == 0,
                f"Found {len(violations)} rows with customer_health_index outside [0,100]: "
                f"{[(r[0], float(r[1])) for r in violations[:5]]}")

        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_customer_retention_risk
            WHERE customer_health_index IS NULL
        """)
        require(int(null_count) == 0,
                f"Found {null_count} rows with NULL customer_health_index")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Percentile Values Between 0 and 1 ============

def component_12_percentile_validation():
    """Verify recency_percentile, frequency_percentile, monetary_percentile, risk_percentile are all between 0 and 1 inclusive."""
    conn, db_type = get_db_connection()
    try:
        percentile_cols = [
            'recency_percentile', 'frequency_percentile',
            'monetary_percentile', 'risk_percentile'
        ]
        for col in percentile_cols:
            violations = execute_query(conn, db_type, f"""
                SELECT customer_id, {col}
                FROM main.rpt_customer_retention_risk
                WHERE {col} < 0 OR {col} > 1
            """)
            require(len(violations) == 0,
                    f"Found {len(violations)} rows with {col} outside [0,1]: "
                    f"{[(r[0], float(r[1])) for r in violations[:5]]}")

            null_count = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM main.rpt_customer_retention_risk
                WHERE {col} IS NULL
            """)
            require(int(null_count) == 0,
                    f"Found {null_count} rows with NULL {col}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 13: Tier Validity Strict ============

def component_13_tier_validity_strict():
    """Verify retention_risk_tier only contains valid values from the defined set."""
    conn, db_type = get_db_connection()
    try:
        valid_tiers = {'churned', 'critical', 'at_risk', 'needs_attention', 'loyal', 'stable'}

        tier_result = execute_query(conn, db_type, """
            SELECT DISTINCT retention_risk_tier
            FROM main.rpt_customer_retention_risk
        """)
        actual_tiers = set()
        for row in tier_result:
            val = row[0]
            require(val is not None, "Found NULL retention_risk_tier - all rows must have a tier")
            actual_tiers.add(val.lower())

        invalid = actual_tiers - valid_tiers
        require(len(invalid) == 0, f"Invalid tier values found: {invalid}. Valid: {valid_tiers}")

        # Verify every single row has a non-null tier
        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_customer_retention_risk
            WHERE retention_risk_tier IS NULL
        """)
        require(int(null_count) == 0,
                f"Found {null_count} rows with NULL retention_risk_tier")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 14: Tier Waterfall Logic Spot-Check ============

def component_14_tier_waterfall_spot_check():
    """For 'churned' rows, verify days_since_last_order > 180 AND total_orders = 1.
       For 'loyal' rows, verify risk_percentile <= 0.20 AND order_frequency >= 1.0 AND return_rate < 0.10."""
    conn, db_type = get_db_connection()
    try:
        # Check churned rows
        churned_violations = execute_query(conn, db_type, """
            SELECT customer_id, days_since_last_order, total_orders
            FROM main.rpt_customer_retention_risk
            WHERE LOWER(retention_risk_tier) = 'churned'
              AND (days_since_last_order <= 180 OR total_orders != 1)
        """)
        require(len(churned_violations) == 0,
                f"Found {len(churned_violations)} 'churned' rows violating conditions "
                f"(days_since_last_order > 180 AND total_orders = 1): "
                f"{[(r[0], float(r[1]), int(r[2])) for r in churned_violations[:5]]}")

        # Check loyal rows
        loyal_violations = execute_query(conn, db_type, """
            SELECT customer_id, risk_percentile, order_frequency, return_rate
            FROM main.rpt_customer_retention_risk
            WHERE LOWER(retention_risk_tier) = 'loyal'
              AND (risk_percentile > 0.20 OR order_frequency < 1.0 OR return_rate >= 0.10)
        """)
        require(len(loyal_violations) == 0,
                f"Found {len(loyal_violations)} 'loyal' rows violating conditions "
                f"(risk_percentile <= 0.20 AND order_frequency >= 1.0 AND return_rate < 0.10): "
                f"{[(r[0], float(r[1]), float(r[2]), float(r[3])) for r in loyal_violations[:5]]}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 15: type_rank Consistency ============

def component_15_type_rank_consistency():
    """Verify type_rank starts at 1 for each customer_type group and max(type_rank) = type_customer_count within each group."""
    conn, db_type = get_db_connection()
    try:
        # Check that min rank is 1 for every customer_type
        min_rank_violations = execute_query(conn, db_type, """
            SELECT customer_type, MIN(type_rank) as min_rank
            FROM main.rpt_customer_retention_risk
            GROUP BY customer_type
            HAVING MIN(type_rank) != 1
        """)
        require(len(min_rank_violations) == 0,
                f"type_rank does not start at 1 for these customer_types: "
                f"{[(r[0], int(r[1])) for r in min_rank_violations]}")

        # Check that type_customer_count matches actual row count per group
        # Accept both COUNT(*) (exact) and MAX(type_rank) via DENSE_RANK (may be
        # lower when ties exist). Require type_customer_count >= 80% of actual count.
        count_violations = execute_query(conn, db_type, """
            SELECT customer_type, MAX(type_customer_count) as type_count,
                   COUNT(*) as actual_count
            FROM main.rpt_customer_retention_risk
            GROUP BY customer_type
            HAVING MAX(type_customer_count) > COUNT(*)
                OR MAX(type_customer_count) < COUNT(*) * 0.8
        """)
        require(len(count_violations) == 0,
                f"type_customer_count out of acceptable range for these customer_types: "
                f"{[(r[0], int(r[1]), int(r[2])) for r in count_violations]}")

        # Check that type_rank does not exceed type_customer_count
        rank_overflow = execute_query(conn, db_type, """
            SELECT customer_id, customer_type, type_rank, type_customer_count
            FROM main.rpt_customer_retention_risk
            WHERE type_rank > type_customer_count
            LIMIT 5
        """)
        require(len(rank_overflow) == 0,
                f"type_rank exceeds type_customer_count: "
                f"{[(r[0], r[1], int(r[2]), int(r[3])) for r in rank_overflow]}")

        # Verify type_customer_count is the same for all rows in each group
        count_consistency = execute_query(conn, db_type, """
            SELECT customer_type, COUNT(DISTINCT type_customer_count) as distinct_counts
            FROM main.rpt_customer_retention_risk
            GROUP BY customer_type
            HAVING COUNT(DISTINCT type_customer_count) != 1
        """)
        require(len(count_consistency) == 0,
                f"type_customer_count is not consistent within groups: "
                f"{[(r[0], int(r[1])) for r in count_consistency]}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 16: above_type_avg_frequency Consistency ============

def component_16_above_type_avg_frequency():
    """For each customer_type, compute AVG(order_frequency) and verify above_type_avg_frequency = 1
       only for customers whose order_frequency is above that average."""
    conn, db_type = get_db_connection()
    try:
        # Get all rows grouped with their type average
        rows = execute_query(conn, db_type, """
            SELECT
                r.customer_id,
                r.customer_type,
                r.order_frequency,
                r.above_type_avg_frequency,
                type_avgs.avg_freq
            FROM main.rpt_customer_retention_risk r
            JOIN (
                SELECT customer_type, AVG(order_frequency) as avg_freq
                FROM main.rpt_customer_retention_risk
                GROUP BY customer_type
            ) type_avgs ON r.customer_type = type_avgs.customer_type
        """)

        errors = []
        for cid, ctype, freq, above_flag, avg_freq in rows:
            freq = float(freq) if freq is not None else 0.0
            avg_freq = float(avg_freq) if avg_freq is not None else 0.0
            above_flag = int(above_flag) if above_flag is not None else 0

            if freq > avg_freq and above_flag != 1:
                errors.append(f"Customer {cid} (type={ctype}): freq={freq:.4f} > avg={avg_freq:.4f} "
                              f"but above_type_avg_frequency={above_flag} (expected 1)")
            elif freq <= avg_freq and above_flag != 0:
                errors.append(f"Customer {cid} (type={ctype}): freq={freq:.4f} <= avg={avg_freq:.4f} "
                              f"but above_type_avg_frequency={above_flag} (expected 0)")

        require(len(errors) == 0,
                f"above_type_avg_frequency mismatches ({len(errors)} total):\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 17: Formula avg_order_value = total_revenue / total_orders ============

def component_17_avg_order_value_formula():
    """Verify avg_order_value = total_revenue / total_orders for sampled rows (handle division by zero)."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT customer_id, total_revenue, total_orders, avg_order_value
            FROM main.rpt_customer_retention_risk
            WHERE total_orders > 0
        """)

        errors = []
        for cid, total_rev, total_ord, actual_aov in rows:
            total_rev = float(total_rev) if total_rev is not None else 0.0
            total_ord = float(total_ord) if total_ord is not None else 0.0
            actual_aov = float(actual_aov) if actual_aov is not None else 0.0

            if total_ord > 0:
                expected_aov = total_rev / total_ord
                if abs(actual_aov - expected_aov) > 0.01:
                    errors.append(f"Customer {cid}: avg_order_value={actual_aov:.4f}, "
                                  f"expected={expected_aov:.4f} "
                                  f"(total_revenue={total_rev:.2f}, total_orders={total_ord})")

        require(len(errors) == 0,
                f"avg_order_value formula mismatches ({len(errors)} total):\n" + "\n".join(errors[:5]))

        # Also check rows with total_orders = 0 have avg_order_value = 0 or NULL
        zero_order_rows = execute_query(conn, db_type, """
            SELECT customer_id, avg_order_value
            FROM main.rpt_customer_retention_risk
            WHERE total_orders = 0 AND avg_order_value IS NOT NULL AND avg_order_value != 0
        """)
        require(len(zero_order_rows) == 0,
                f"Found {len(zero_order_rows)} rows with total_orders=0 but non-zero avg_order_value: "
                f"{[(r[0], float(r[1])) for r in zero_order_rows[:5]]}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 18: Formula net_revenue = total_revenue - total_refund_amount ============

def component_18_net_revenue_formula():
    """Verify net_revenue = total_revenue - total_refund_amount for all rows."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT customer_id, total_revenue, total_refund_amount, net_revenue
            FROM main.rpt_customer_retention_risk
        """)

        errors = []
        for cid, total_rev, total_refund, actual_net in rows:
            total_rev = float(total_rev) if total_rev is not None else 0.0
            total_refund = float(total_refund) if total_refund is not None else 0.0
            actual_net = float(actual_net) if actual_net is not None else 0.0

            expected_net = total_rev - total_refund
            if abs(actual_net - expected_net) > 0.01:
                errors.append(f"Customer {cid}: net_revenue={actual_net:.4f}, "
                              f"expected={expected_net:.4f} "
                              f"(total_revenue={total_rev:.2f}, total_refund_amount={total_refund:.2f})")

        require(len(errors) == 0,
                f"net_revenue formula mismatches ({len(errors)} total):\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_risk_score_bounds": 1.0,
    "component_6_uses_window_functions": 1.0,
    "component_7_waterfall_tier_logic": 1.0,
    "component_8_uses_reference_date": 1.0,
    "component_9_risk_score_formula": 1.0,
    "component_10_retention_risk_score_strict_bounds": 1.0,
    "component_11_customer_health_index_strict_bounds": 1.0,
    "component_12_percentile_validation": 1.0,
    "component_13_tier_validity_strict": 1.0,
    "component_14_tier_waterfall_spot_check": 1.0,
    "component_15_type_rank_consistency": 1.0,
    "component_16_above_type_avg_frequency": 1.0,
    "component_17_avg_order_value_formula": 1.0,
    "component_18_net_revenue_formula": 1.0,
}


def test_solution():
    scores = {}

    for component_name in WEIGHTS:
        try:
            component_func = globals()[component_name]
            scores[component_name] = component_func()
            print(f"PASS: {component_name}")
        except Exception as e:
            scores[component_name] = 0.0
            print(f"FAIL: {component_name}: {e}")

    all_passed = all(scores.get(key, 0) == 1.0 for key in WEIGHTS)
    final_score = 1.0 if all_passed else 0.0

    Path("/logs/verifier").mkdir(parents=True, exist_ok=True)
    Path("/logs/verifier/reward.txt").write_text(str(final_score))
    # Harbor requires reward.json to be a single-key dict[str, float|int]
    # (harbor.utils.pass_at_k rejects len(rewards) != 1; VerifierResult.rewards
    # is dict[str, float|int]). Emit the overall score as {"reward": ...},
    # matching reward.txt; per-component pass/fail is in the verifier stdout above.
    Path("/logs/verifier/reward.json").write_text(json.dumps({"reward": final_score}))

    print(f"\nFinal Score: {final_score}")
    assert final_score == 1.0, f"Score: {final_score}"
