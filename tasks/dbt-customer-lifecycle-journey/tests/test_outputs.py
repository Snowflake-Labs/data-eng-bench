"""Test verifier for dbt-customer-lifecycle-journey"""
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
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def component_1_models_compile():
    """All dbt models compile and run successfully"""
    run_cmd("dbt deps")
    result = run_cmd("dbt run -s stg_customer__lifecycle_events int_customer__journey_metrics mart_customer__lifecycle_scorecard")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


def component_2_staging_columns():
    """Staging model has all required columns"""
    conn, db_type = get_db_connection()
    try:
        required = ['customer_id', 'first_event_date', 'last_event_date', 'total_lifecycle_events',
                    'activation_date', 'reactivation_count', 'days_since_activation', 'days_since_last_event',
                    'current_segment', 'lifecycle_stage']
        columns = execute_query(conn, db_type,
            "SELECT column_name FROM information_schema.columns WHERE lower(table_name) = 'stg_customer__lifecycle_events'")
        actual = {c[0].lower() for c in columns}
        missing = [c for c in required if c.lower() not in actual]
        require(len(missing) == 0, f"Missing staging columns: {missing}")
        return 1.0
    finally:
        conn.close()


def component_3_intermediate_columns():
    """Intermediate model has all required columns"""
    conn, db_type = get_db_connection()
    try:
        required = ['journey_velocity_score', 'time_to_activate', 'events_per_month',
                    'orders_count', 'total_order_value', 'engagement_consistency',
                    'avg_days_between_events', 'activation_rate']
        columns = execute_query(conn, db_type,
            "SELECT column_name FROM information_schema.columns WHERE lower(table_name) = 'int_customer__journey_metrics'")
        actual = {c[0].lower() for c in columns}
        missing = [c for c in required if c.lower() not in actual]
        require(len(missing) == 0, f"Missing intermediate columns: {missing}")
        return 1.0
    finally:
        conn.close()


def component_4_mart_columns():
    """Mart model has all required columns"""
    conn, db_type = get_db_connection()
    try:
        required = ['velocity_percentile', 'engagement_percentile', 'value_percentile', 'consistency_percentile',
                    'lifecycle_health_tier', 'customer_lifecycle_index', 'churn_risk_score',
                    'segment_velocity_rank', 'segment_peer_count', 'above_segment_avg_velocity', 'segment_percentile']
        columns = execute_query(conn, db_type,
            "SELECT column_name FROM information_schema.columns WHERE lower(table_name) = 'mart_customer__lifecycle_scorecard'")
        actual = {c[0].lower() for c in columns}
        missing = [c for c in required if c.lower() not in actual]
        require(len(missing) == 0, f"Missing mart columns: {missing}")
        return 1.0
    finally:
        conn.close()


def component_5_no_inf_nan():
    """No infinite or NaN values in numeric fields"""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT journey_velocity_score, customer_lifecycle_index, churn_risk_score
            FROM main.mart_customer__lifecycle_scorecard
        """)
        for row in rows:
            for v in row:
                if v is not None:
                    v_float = float(v)
                    require(not (math.isinf(v_float) or math.isnan(v_float)), f"inf/nan found: {v}")
        return 1.0
    finally:
        conn.close()


def component_6_score_bounds():
    """All scores are bounded 0-100"""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT MIN(journey_velocity_score), MAX(journey_velocity_score),
                   MIN(customer_lifecycle_index), MAX(customer_lifecycle_index),
                   MIN(churn_risk_score), MAX(churn_risk_score)
            FROM main.mart_customer__lifecycle_scorecard
        """)
        row = result[0]
        min_v, max_v, min_i, max_i, min_c, max_c = row
        for label, min_val, max_val in [('velocity', min_v, max_v), ('lifecycle_index', min_i, max_i), ('churn_risk', min_c, max_c)]:
            min_val = float(min_val) if min_val else 0
            max_val = float(max_val) if max_val else 0
            require(min_val >= -0.01 and max_val <= 100.01, f"{label} out of bounds: {min_val}-{max_val}")
        return 1.0
    finally:
        conn.close()


def component_7_lifecycle_stages_valid():
    """Lifecycle stages are valid values"""
    conn, db_type = get_db_connection()
    try:
        stages = execute_query(conn, db_type, "SELECT DISTINCT lifecycle_stage FROM main.stg_customer__lifecycle_events")
        valid = {'NEW', 'DORMANT', 'AT_RISK', 'ACTIVE', 'ACTIVATED'}
        actual = {s[0] for s in stages if s[0]}
        invalid = actual - valid
        require(len(invalid) == 0, f"Invalid lifecycle stages: {invalid}")
        return 1.0
    finally:
        conn.close()


def component_8_health_tiers_valid():
    """Lifecycle health tiers are valid values"""
    conn, db_type = get_db_connection()
    try:
        tiers = execute_query(conn, db_type, "SELECT DISTINCT lifecycle_health_tier FROM main.mart_customer__lifecycle_scorecard")
        valid = {'thriving', 'growing', 'stable', 'at_risk', 'dormant'}
        actual = {t[0].lower() for t in tiers if t[0]}
        invalid = actual - valid
        require(len(invalid) == 0, f"Invalid health tiers: {invalid}")
        return 1.0
    finally:
        conn.close()


def component_9_percentiles_valid():
    """Percentile values are in 0-1 range"""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT MIN(velocity_percentile), MAX(velocity_percentile),
                   MIN(engagement_percentile), MAX(engagement_percentile),
                   MIN(value_percentile), MAX(value_percentile),
                   MIN(consistency_percentile), MAX(consistency_percentile),
                   MIN(segment_percentile), MAX(segment_percentile)
            FROM main.mart_customer__lifecycle_scorecard
        """)
        row = result[0]
        for i, v in enumerate(row):
            if v is not None:
                v = float(v)
                require(v >= -0.01 and v <= 1.01, f"Percentile {i} out of range: {v}")
        return 1.0
    finally:
        conn.close()


def component_10_segment_rank_valid():
    """Each segment has rank 1"""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT current_segment, MIN(segment_velocity_rank)
            FROM main.mart_customer__lifecycle_scorecard
            WHERE current_segment IS NOT NULL
            GROUP BY current_segment
        """)
        for seg, rank in result:
            require(int(rank) == 1, f"Segment {seg}: min rank={rank}, expected 1")
        return 1.0
    finally:
        conn.close()


def component_11_activation_rate_valid():
    """Activation rate is 0 or 1"""
    conn, db_type = get_db_connection()
    try:
        invalid = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.int_customer__journey_metrics
            WHERE activation_rate NOT IN (0, 1)
        """)
        require(int(invalid) == 0, f"{invalid} rows have invalid activation_rate")
        return 1.0
    finally:
        conn.close()


def component_12_thriving_criteria():
    """Thriving tier meets documented criteria"""
    conn, db_type = get_db_connection()
    try:
        invalid = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.mart_customer__lifecycle_scorecard
            WHERE lifecycle_health_tier = 'thriving'
            AND NOT (
                COALESCE(velocity_percentile, 0) >= 0.80
                AND COALESCE(orders_count, 0) >= 4
                AND COALESCE(days_since_activation, 999) < 120
                AND COALESCE(engagement_consistency, 0) > 0.5
            )
        """)
        require(int(invalid) == 0, f"{invalid} thriving customers don't meet criteria")
        return 1.0
    finally:
        conn.close()


def component_13_days_since_last_event():
    """days_since_last_event is calculated correctly"""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT customer_id, last_event_date, reference_date, days_since_last_event
            FROM main.stg_customer__lifecycle_events
            LIMIT 10
        """)
        for cid, last_date, ref_date, days_since in result:
            if last_date and ref_date and days_since is not None:
                from datetime import datetime, date
                if isinstance(last_date, str):
                    last_dt = datetime.fromisoformat(last_date.replace('Z', '+00:00'))
                    ref_dt = datetime.fromisoformat(ref_date.replace('Z', '+00:00'))
                elif isinstance(last_date, date) and not isinstance(last_date, datetime):
                    last_dt = last_date
                    ref_dt = ref_date
                else:
                    last_dt = last_date
                    ref_dt = ref_date
                if isinstance(last_dt, date) and isinstance(ref_dt, date):
                    expected = (ref_dt - last_dt).days
                else:
                    expected = (ref_dt - last_dt).days
                require(abs(int(days_since) - expected) <= 1, f"Customer {cid}: days_since={days_since}, expected~{expected}")
        return 1.0
    finally:
        conn.close()


def component_14_at_risk_tier_logic():
    """at_risk tier meets criteria"""
    conn, db_type = get_db_connection()
    try:
        invalid = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.mart_customer__lifecycle_scorecard
            WHERE lifecycle_health_tier = 'at_risk'
            AND NOT (
                COALESCE(days_since_last_event, 999) >= 45
                AND COALESCE(velocity_percentile, 0) < 0.30
            )
        """)
        require(int(invalid) == 0, f"{invalid} at_risk customers don't meet criteria")
        return 1.0
    finally:
        conn.close()


WEIGHTS = {f"component_{i}_{n}": 1.0 for i, n in enumerate([
    "models_compile", "staging_columns", "intermediate_columns", "mart_columns",
    "no_inf_nan", "score_bounds", "lifecycle_stages_valid", "health_tiers_valid",
    "percentiles_valid", "segment_rank_valid", "activation_rate_valid", "thriving_criteria",
    "days_since_last_event", "at_risk_tier_logic"
], 1)}

def test_solution():
    """Run all customer lifecycle journey verification components and assert all pass."""
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
