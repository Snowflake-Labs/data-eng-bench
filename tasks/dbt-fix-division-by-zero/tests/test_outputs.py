"""
Test verifier for dbt-fix-division-by-zero task.

Components:
1. Model compiles and runs successfully
2. No inf/nan values in output
3. Row count matches source (no incorrect filtering)
4. ltv_tier column exists
5. ltv_tier has valid values (7 tiers: vip/platinum/gold/silver/bronze/at_risk/inactive)
6. Uses window function for percentile calculation
7. Tier distribution is reasonable (not all same tier)
8. All new columns exist (engagement_score, churn_risk_score, peer metrics)
9. Engagement score formula matches exact weights (30%, 35%, 35%)
10. Churn risk score formula matches exact weights (40%, 30%, 30%)
11. Engagement score bounded 0-100
12. Churn risk score bounded 0-100
13. customer_value_rank uses DENSE_RANK correctly
14. above_median_revenue calculated correctly
15. LTV tier waterfall logic with 7 tiers
"""
import subprocess
import math
import json
import os
import re
from pathlib import Path
from decimal import Decimal


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
        # Try password auth first (many Snowflake accounts use password, not private key)
        password = os.environ.get('SNOWFLAKE_PASSWORD')
        if password:
            conn = snowflake.connector.connect(
                account=os.environ['SNOWFLAKE_ACCOUNT'],
                host=os.environ.get('SNOWFLAKE_HOST') or None,
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
            host=os.environ.get('SNOWFLAKE_HOST') or None,
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def run_cmd(cmd, cwd=None):
    """Run a shell command and return the result."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    """Read the model SQL file."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        model_path = "/app/dbt_models_snowflake/models/marts/customer/rpt_customer_metrics.sql"
    else:
        model_path = f"{get_dbt_project_dir()}/models/marts/customer/rpt_customer_metrics.sql"
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    """Assert with descriptive message."""
    if not condition:
        raise AssertionError(message)


def to_float(val):
    """Safely convert a value (possibly Decimal) to float."""
    if val is None:
        return None
    return float(val)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    """Model should compile and run without error."""
    # First run dbt deps to install packages
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    result = run_cmd("dbt run -s rpt_customer_metrics")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """No infinity or NaN values in numeric columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT avg_order_value, orders_per_month, revenue_velocity_ratio, order_frequency_trend
            FROM main.rpt_customer_metrics
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None:
                    fval = float(val)
                    if math.isinf(fval) or math.isnan(fval):
                        inf_nan_count += 1

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    """All customers must be included."""
    conn, db_type = get_db_connection()
    try:
        output_count = execute_scalar(conn, db_type,
            "SELECT COUNT(*) FROM main.rpt_customer_metrics")
        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT customer_id) FROM main.int_sales__orders_enriched
            WHERE status != 'CANCELLED' AND customer_id IS NOT NULL
        """)

        require(output_count == source_count, f"Row count mismatch: {output_count} vs {source_count}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: ltv_tier Column Exists ============

def component_4_ltv_tier_exists():
    """ltv_tier column must exist."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT ltv_tier FROM main.rpt_customer_metrics LIMIT 1
        """)
        require(result is not None and len(result) > 0, "ltv_tier column missing or empty")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: ltv_tier Valid Values ============

def component_5_ltv_tier_valid_values():
    """ltv_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT ltv_tier FROM main.rpt_customer_metrics
        """)

        valid_tiers = {'vip', 'platinum', 'gold', 'silver', 'bronze', 'at_risk', 'inactive'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid tier values: {invalid}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Uses Window Function ============

def component_6_uses_window_function():
    """Must use PERCENT_RANK() or NTILE() for percentile calculation."""
    sql = read_model_file().lower()

    has_percent_rank = 'percent_rank()' in sql or 'percent_rank ()' in sql
    has_ntile = 'ntile(' in sql

    require(has_percent_rank or has_ntile,
            "Must use PERCENT_RANK() or NTILE() window function for tier calculation")
    return 1.0


# ============ COMPONENT 7: Tier Distribution ============

def component_7_tier_distribution():
    """Tiers must have reasonable distribution (not all same)."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT ltv_tier, COUNT(*) as cnt
            FROM main.rpt_customer_metrics
            GROUP BY ltv_tier
        """)

        tier_counts = {row[0]: row[1] for row in result if row[0]}

        # Must have at least 2 different tiers
        require(len(tier_counts) >= 2, f"Only {len(tier_counts)} tier(s) found - logic may be wrong")

        # No single tier should have more than 90% of customers
        total = sum(tier_counts.values())
        for tier, count in tier_counts.items():
            pct = count / total
            require(pct < 0.90, f"Tier '{tier}' has {pct*100:.1f}% of customers - distribution is wrong")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: New Columns Exist ============

def component_8_new_columns_exist():
    """Verify all new columns exist."""
    conn, db_type = get_db_connection()
    try:
        required = [
            'days_since_last_order', 'orders_last_180d', 'customer_engagement_score',
            'churn_risk_score', 'customer_value_rank', 'customer_value_percentile',
            'above_median_revenue'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.rpt_customer_metrics LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.rpt_customer_metrics LIMIT 1")
            actual = [col[0].lower() for col in result.description]

        missing = [col for col in required if col not in actual]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 9: Engagement Score Formula ============

def component_9_engagement_score_formula():
    """Validate customer_engagement_score formula exactly."""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT
                customer_id,
                days_since_last_order,
                orders_per_month,
                PERCENT_RANK() OVER (ORDER BY total_revenue) as revenue_pct,
                customer_engagement_score
            FROM main.rpt_customer_metrics
            ORDER BY customer_id
            LIMIT 20
        """)

        errors = []
        for cid, days_inactive, opm, rev_pct, actual_score in results:
            # Convert to float for safety (handles Decimal types)
            days_inactive = to_float(days_inactive) if days_inactive is not None else 365
            opm = to_float(opm) if opm is not None else 0
            rev_pct = to_float(rev_pct) if rev_pct is not None else 0
            actual_score = to_float(actual_score) if actual_score is not None else 0

            # Recalculate expected score
            recency = min(1.0, max(0, (365 - days_inactive) / 365))
            frequency = min(1.0, max(0, opm / 5.0))
            monetary = rev_pct

            expected = (recency * 0.30 + frequency * 0.35 + monetary * 0.35) * 100

            if abs(actual_score - expected) > 1.0:
                errors.append(f"Customer {cid}: score={actual_score:.2f}, expected={expected:.2f}")

        require(len(errors) == 0, f"Engagement score formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Churn Risk Score Formula ============

def component_10_churn_risk_score_formula():
    """Validate churn_risk_score formula exactly."""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT
                customer_id,
                days_since_last_order,
                order_frequency_trend,
                revenue_velocity_ratio,
                churn_risk_score
            FROM main.rpt_customer_metrics
            ORDER BY customer_id
            LIMIT 20
        """)

        errors = []
        for cid, days_inactive, oft, rvr, actual_score in results:
            # Convert to float for safety (handles Decimal types)
            days_inactive = to_float(days_inactive) if days_inactive is not None else 365
            oft = to_float(oft) if oft is not None else 0
            rvr = to_float(rvr) if rvr is not None else 0
            actual_score = to_float(actual_score) if actual_score is not None else 0

            # Recalculate expected score
            inactive_factor = min(1.0, max(0, days_inactive / 365))
            declining_orders = 1.0 - min(1.0, max(0, oft))
            declining_revenue = 1.0 - min(1.0, max(0, rvr))

            expected = (inactive_factor * 0.40 + declining_orders * 0.30 + declining_revenue * 0.30) * 100

            if abs(actual_score - expected) > 1.0:
                errors.append(f"Customer {cid}: score={actual_score:.2f}, expected={expected:.2f}")

        require(len(errors) == 0, f"Churn risk score formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Engagement Score Bounds ============

def component_11_engagement_score_bounds():
    """Engagement score must be bounded 0-100."""
    conn, db_type = get_db_connection()
    try:
        bounds = execute_query(conn, db_type, """
            SELECT MIN(customer_engagement_score), MAX(customer_engagement_score)
            FROM main.rpt_customer_metrics
        """)

        min_val = to_float(bounds[0][0]) if bounds[0][0] is not None else None
        max_val = to_float(bounds[0][1]) if bounds[0][1] is not None else None

        if min_val is not None:
            require(min_val >= -0.01, f"Engagement score below 0: {min_val}")
        if max_val is not None:
            require(max_val <= 100.01, f"Engagement score above 100: {max_val}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Churn Risk Score Bounds ============

def component_12_churn_risk_score_bounds():
    """Churn risk score must be bounded 0-100."""
    conn, db_type = get_db_connection()
    try:
        bounds = execute_query(conn, db_type, """
            SELECT MIN(churn_risk_score), MAX(churn_risk_score)
            FROM main.rpt_customer_metrics
        """)

        min_val = to_float(bounds[0][0]) if bounds[0][0] is not None else None
        max_val = to_float(bounds[0][1]) if bounds[0][1] is not None else None

        if min_val is not None:
            require(min_val >= -0.01, f"Churn risk score below 0: {min_val}")
        if max_val is not None:
            require(max_val <= 100.01, f"Churn risk score above 100: {max_val}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 13: Customer Value Rank ============

def component_13_customer_value_rank():
    """Verify customer_value_rank uses DENSE_RANK correctly."""
    conn, db_type = get_db_connection()
    try:
        # Check that rank 1 exists
        rank_1 = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_customer_metrics
            WHERE customer_value_rank = 1
        """)

        require(rank_1 > 0, "No customer has rank 1 - DENSE_RANK not used correctly")

        # Check highest revenue has rank 1
        top_revenue = execute_query(conn, db_type, """
            SELECT customer_id, total_revenue, customer_value_rank
            FROM main.rpt_customer_metrics
            ORDER BY total_revenue DESC
            LIMIT 1
        """)

        require(int(top_revenue[0][2]) == 1,
                f"Highest revenue customer {top_revenue[0][0]} has rank {top_revenue[0][2]}, not 1")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 14: Above Median Revenue ============

def component_14_above_median_revenue():
    """Validate above_median_revenue calculation."""
    conn, db_type = get_db_connection()
    try:
        # Calculate median using a compatible approach
        if db_type == 'snowflake':
            median = to_float(execute_scalar(conn, db_type, """
                SELECT MEDIAN(total_revenue)
                FROM main.rpt_customer_metrics
            """))
        else:
            median = to_float(execute_scalar(conn, db_type, """
                SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_revenue)
                FROM main.rpt_customer_metrics
            """))

        results = execute_query(conn, db_type, """
            SELECT customer_id, total_revenue, above_median_revenue
            FROM main.rpt_customer_metrics
            ORDER BY customer_id
            LIMIT 20
        """)

        errors = []
        for cid, revenue, flag in results:
            revenue = to_float(revenue) if revenue is not None else 0
            expected = 1 if revenue > median else 0
            actual_flag = int(flag) if flag is not None else 0
            if actual_flag != expected:
                errors.append(f"Customer {cid}: flag={actual_flag}, expected={expected}")

        require(len(errors) == 0, f"above_median_revenue errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 15: LTV Tier Waterfall Logic ============

def component_15_ltv_tier_waterfall_logic():
    """Validate LTV tier waterfall with 7 tiers."""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT
                customer_id,
                PERCENT_RANK() OVER (ORDER BY total_revenue) as rev_pct,
                orders_last_90d,
                orders_last_180d,
                total_orders,
                avg_order_value,
                total_revenue,
                days_since_last_order,
                ltv_tier
            FROM main.rpt_customer_metrics
            ORDER BY customer_id
            LIMIT 30
        """)

        errors = []
        for cid, rev_pct, o90, o180, tot_orders, aov, tot_rev, days_inactive, actual_tier in results:
            # Convert to float for safety
            rev_pct = to_float(rev_pct) if rev_pct is not None else 0
            o90 = int(o90) if o90 is not None else 0
            o180 = int(o180) if o180 is not None else 0
            tot_orders = int(tot_orders) if tot_orders is not None else 0
            aov = to_float(aov) if aov is not None else 0
            tot_rev = to_float(tot_rev) if tot_rev is not None else 0
            days_inactive = int(days_inactive) if days_inactive is not None else 0

            # Waterfall logic
            if rev_pct >= 0.95 and o90 > 0 and tot_orders >= 10:
                expected = 'vip'
            elif rev_pct >= 0.90 and o180 > 0:
                expected = 'platinum'
            elif rev_pct >= 0.75 or aov > 500:
                expected = 'gold'
            elif tot_orders >= 3 and tot_rev > 100:
                expected = 'silver'
            elif tot_orders >= 1 and tot_rev > 50:
                expected = 'bronze'
            elif tot_orders > 0 and days_inactive > 365:
                expected = 'at_risk'
            else:
                expected = 'inactive'

            if actual_tier and actual_tier.lower() != expected:
                errors.append(f"Customer {cid}: tier='{actual_tier}', expected='{expected}'")

        require(len(errors) == 0, f"LTV tier waterfall errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ WEIGHTS AND SCORING ============

WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_ltv_tier_exists": 1.0,
    "component_5_ltv_tier_valid_values": 1.0,
    "component_6_uses_window_function": 1.0,
    "component_7_tier_distribution": 1.0,
    "component_8_new_columns_exist": 1.0,
    "component_9_engagement_score_formula": 1.0,
    "component_10_churn_risk_score_formula": 1.0,
    "component_11_engagement_score_bounds": 1.0,
    "component_12_churn_risk_score_bounds": 1.0,
    "component_13_customer_value_rank": 1.0,
    "component_14_above_median_revenue": 1.0,
    "component_15_ltv_tier_waterfall_logic": 1.0,
}


def test_solution():
    """Run all component tests and compute final score."""
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
