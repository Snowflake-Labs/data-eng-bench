"""
Test verifier for dbt-payment-analytics task.

Components:
1. Model compiles and runs successfully
2. No inf/nan values in output
3. Row count matches distinct payment methods
4. All required columns exist (including new peer metrics)
5. payment_health_tier has valid values
6. provider_type correctly assigned based on payment method name
7. Peer metrics partitioned by provider_type correctly
8. Uses DENSE_RANK for provider_success_rank
9. Uses PERCENT_RANK for provider_volume_percentile
10. above_provider_avg_success correctly calculated
11. reliability_score bounded 0-100 and formula validated
12. Waterfall tier logic validated
"""
import subprocess
import os
import re
import math
import json
from pathlib import Path


# ============ DUAL-BACKEND INFRASTRUCTURE ============


def load_snowflake_env():
    """Load Snowflake environment variables from file if available."""
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
    """Load private key from base64-encoded env var."""
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
    """Create a database connection based on DB_TYPE environment variable."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        import snowflake.connector
        # Try password auth first (the eval connection uses password, not private key)
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
    """Execute a query and return results, handling differences between DuckDB and Snowflake."""
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
    """Execute a query and return a single scalar value."""
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
    if cwd is None:
        cwd = get_dbt_project_dir()
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    """Read the model SQL file."""
    model_path = f"{get_dbt_project_dir()}/models/marts/sales/rpt_payment_analytics.sql"
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    """Assert with descriptive message."""
    if not condition:
        raise AssertionError(message)


def get_expected_provider_type(payment_method):
    """Calculate expected provider type based on payment method name."""
    pm_upper = payment_method.upper()
    if any(x in pm_upper for x in ['CREDIT', 'DEBIT', 'CARD', 'VISA', 'MASTERCARD', 'AMEX', 'DISCOVER']):
        return 'CARD'
    elif any(x in pm_upper for x in ['PAYPAL', 'VENMO', 'APPLE', 'GOOGLE', 'WALLET']):
        return 'DIGITAL'
    elif any(x in pm_upper for x in ['BANK', 'ACH', 'WIRE', 'TRANSFER']):
        return 'BANK'
    else:
        return 'OTHER'


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    """Model should compile and run without error."""
    result = run_cmd("dbt run -s rpt_payment_analytics")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """No infinity or NaN values in numeric columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                total_amount,
                successful_amount,
                success_rate,
                avg_transaction_amount,
                failure_rate,
                provider_volume_percentile,
                reliability_score
            FROM main.rpt_payment_analytics
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
    """All payment methods must be included."""
    conn, db_type = get_db_connection()
    try:
        output_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_payment_analytics
        """)

        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT p.payment_method)
            FROM main.stg_orders__order_payments p
            INNER JOIN main.int_sales__orders_enriched o ON p.order_id = o.ORDER_ID
            WHERE UPPER(o.status) NOT IN ('CANCELLED', 'C')
              AND p.payment_method IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns Exist ============

def component_4_required_columns():
    """All required columns must exist including new peer metrics."""
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'payment_method', 'provider_type', 'total_transactions', 'total_orders',
            'total_amount', 'successful_amount', 'failed_transactions', 'pending_transactions',
            'success_rate', 'avg_transaction_amount', 'failure_rate',
            # New peer comparison columns
            'provider_success_rank', 'provider_method_count',
            'above_provider_avg_success', 'provider_volume_percentile',
            # Composite score and tier
            'reliability_score', 'payment_health_tier'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.rpt_payment_analytics LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.rpt_payment_analytics LIMIT 1")
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Tier Values ============

def component_5_valid_tier_values():
    """payment_health_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT payment_health_tier FROM main.rpt_payment_analytics
        """)

        valid_tiers = {'excellent', 'good', 'concerning', 'problematic', 'critical'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid tier values found: {invalid}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Provider Type Correctly Assigned ============

def component_6_provider_type_assignment():
    """provider_type must be correctly assigned based on payment method name."""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT payment_method, provider_type
            FROM main.rpt_payment_analytics
        """)

        errors = []
        for pm, actual_type in results:
            expected_type = get_expected_provider_type(pm)
            if actual_type.upper() != expected_type:
                errors.append(f"Payment '{pm}': provider_type='{actual_type}', expected='{expected_type}'")

        require(len(errors) == 0, f"Provider type mismatches:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 7: Peer Metrics Partitioned Correctly ============

def component_7_peer_metrics_partitioned():
    """Peer metrics must be partitioned by provider_type - each type should have rank 1."""
    conn, db_type = get_db_connection()
    try:
        # Check that each provider_type has a method with rank 1
        result = execute_query(conn, db_type, """
            SELECT provider_type, MIN(provider_success_rank) as min_rank
            FROM main.rpt_payment_analytics
            GROUP BY provider_type
        """)

        for ptype, min_rank in result:
            require(min_rank == 1,
                    f"Provider type '{ptype}' has min rank={min_rank}, should be 1. "
                    f"Window function not partitioned by provider_type correctly.")

        # Check provider_method_count matches actual count per provider
        count_check = execute_query(conn, db_type, """
            SELECT provider_type, provider_method_count, COUNT(*) as actual_count
            FROM main.rpt_payment_analytics
            GROUP BY provider_type, provider_method_count
            HAVING provider_method_count != COUNT(*)
        """)

        require(len(count_check) == 0,
                f"provider_method_count mismatch: {count_check}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: Uses DENSE_RANK for Ranking ============

def component_8_uses_dense_rank():
    """Must use DENSE_RANK() for provider_success_rank."""
    sql = read_model_file().lower()

    has_dense_rank = 'dense_rank()' in sql or 'dense_rank ()' in sql

    require(has_dense_rank,
            "Must use DENSE_RANK() window function for provider_success_rank")
    return 1.0


# ============ COMPONENT 9: Uses PERCENT_RANK for Percentile ============

def component_9_uses_percent_rank():
    """Must use PERCENT_RANK() for provider_volume_percentile."""
    sql = read_model_file().lower()

    has_percent_rank = 'percent_rank()' in sql or 'percent_rank ()' in sql

    require(has_percent_rank,
            "Must use PERCENT_RANK() window function for provider_volume_percentile")
    return 1.0


# ============ COMPONENT 10: Above Provider Avg Success ============

def component_10_above_provider_avg():
    """above_provider_avg_success must be correctly calculated."""
    conn, db_type = get_db_connection()
    try:
        mismatches = execute_query(conn, db_type, """
            WITH provider_avgs AS (
                SELECT provider_type, AVG(success_rate) as avg_sr
                FROM main.rpt_payment_analytics
                GROUP BY provider_type
            )
            SELECT r.payment_method, r.success_rate, pa.avg_sr, r.above_provider_avg_success,
                   CASE WHEN r.success_rate > pa.avg_sr THEN 1 ELSE 0 END as expected
            FROM main.rpt_payment_analytics r
            JOIN provider_avgs pa ON r.provider_type = pa.provider_type
            WHERE r.above_provider_avg_success != (CASE WHEN r.success_rate > pa.avg_sr THEN 1 ELSE 0 END)
        """)

        require(len(mismatches) == 0,
                f"above_provider_avg_success mismatches: {mismatches[:5]}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Reliability Score Validation ============

def component_11_reliability_score():
    """reliability_score must be bounded 0-100 and follow expected formula."""
    conn, db_type = get_db_connection()
    try:
        # Check bounds
        bounds = execute_query(conn, db_type, """
            SELECT MIN(reliability_score), MAX(reliability_score)
            FROM main.rpt_payment_analytics
        """)

        min_rs, max_rs = bounds[0]
        if min_rs is not None:
            require(min_rs >= 0, f"reliability_score has value below 0: {min_rs}")
        if max_rs is not None:
            require(max_rs <= 100.01, f"reliability_score exceeds 100: {max_rs}")

        # Validate formula: success_rate*0.40 + (1-failure_rate)*0.30 + volume_factor*0.15 + amount_factor*0.15
        results = execute_query(conn, db_type, """
            SELECT
                payment_method,
                success_rate,
                failure_rate,
                total_transactions,
                avg_transaction_amount,
                reliability_score
            FROM main.rpt_payment_analytics
            WHERE reliability_score IS NOT NULL
        """)

        for pm, sr, fr, txns, avg_amt, actual_rs in results:
            sr = float(sr or 0)
            fr = float(fr or 0)
            txns = float(txns or 0)
            avg_amt = float(avg_amt or 0)
            actual_rs = float(actual_rs or 0)

            volume_factor = min(txns / 1000.0, 1.0)
            amount_factor = min(avg_amt / 500.0, 1.0)
            expected_rs = (sr * 0.40 + (1 - fr) * 0.30 + volume_factor * 0.15 + amount_factor * 0.15) * 100
            expected_rs = min(100, max(0, expected_rs))

            require(abs(actual_rs - expected_rs) < 1.0,
                    f"Payment {pm}: reliability_score={actual_rs}, expected={expected_rs:.2f} "
                    f"(sr={sr:.3f}, fr={fr:.3f}, vol_f={volume_factor:.3f}, amt_f={amount_factor:.3f})")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Waterfall Tier Logic ============

def component_12_waterfall_tier_logic():
    """payment_health_tier must follow strict waterfall logic."""
    conn, db_type = get_db_connection()
    try:
        # Get all data needed for tier calculation
        results = execute_query(conn, db_type, """
            WITH provider_stats AS (
                SELECT
                    provider_type,
                    AVG(success_rate) as avg_sr
                FROM main.rpt_payment_analytics
                GROUP BY provider_type
            ),
            reliability_percentiles AS (
                SELECT
                    r.payment_method,
                    r.provider_type,
                    PERCENT_RANK() OVER (PARTITION BY r.provider_type ORDER BY r.reliability_score) as rel_pct
                FROM main.rpt_payment_analytics r
            )
            SELECT
                r.payment_method,
                r.success_rate,
                r.failure_rate,
                r.reliability_score,
                r.above_provider_avg_success,
                r.payment_health_tier,
                ps.avg_sr as provider_avg,
                rp.rel_pct
            FROM main.rpt_payment_analytics r
            JOIN provider_stats ps ON r.provider_type = ps.provider_type
            JOIN reliability_percentiles rp ON r.payment_method = rp.payment_method
        """)

        errors = []
        for row in results:
            pm, sr, fr, rs, above_avg, actual_tier, prov_avg, rel_pct = row
            sr = float(sr or 0)
            fr = float(fr or 0)
            rs = float(rs or 0)
            above_avg = float(above_avg or 0)

            # Waterfall logic (check worst first)
            if fr >= 0.15 or sr < 0.70:
                expected = 'critical'
            elif fr >= 0.08 or above_avg == 0:
                expected = 'problematic'
            elif fr >= 0.03 or sr < 0.90:
                expected = 'concerning'
            elif rel_pct >= 0.75 and fr < 0.02:
                expected = 'excellent'
            elif above_avg == 1 and rs >= 60:
                expected = 'good'
            else:
                expected = 'concerning'

            if actual_tier.lower() != expected:
                errors.append(f"Payment {pm}: tier='{actual_tier}', expected='{expected}' "
                              f"(sr={sr:.3f}, fr={fr:.3f}, rs={rs:.1f}, "
                              f"above_avg={above_avg}, rel_pct={rel_pct:.2f})")

        require(len(errors) == 0, f"Tier mismatches:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ WEIGHTS AND SCORING ============

WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_valid_tier_values": 1.0,
    "component_6_provider_type_assignment": 1.0,
    "component_7_peer_metrics_partitioned": 1.0,
    "component_8_uses_dense_rank": 1.0,
    "component_9_uses_percent_rank": 1.0,
    "component_10_above_provider_avg": 1.0,
    "component_11_reliability_score": 1.0,
    "component_12_waterfall_tier_logic": 1.0,
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
