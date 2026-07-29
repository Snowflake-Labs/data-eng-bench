"""Test verifier for dbt-cart-abandonment-recovery"""
import subprocess, math, json, os
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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')



def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def component_1_models_compile():
    run_cmd("dbt deps")
    result = run_cmd("dbt run -s stg_ecommerce__abandoned_carts int_ecommerce__cart_recovery_metrics mart_ecommerce__recovery_scorecard")
    require(result.returncode == 0, "dbt run failed")
    return 1.0

def component_2_no_inf_nan():
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, "SELECT recovery_priority_score, engagement_level, conversion_likelihood_index FROM main.mart_ecommerce__recovery_scorecard")
        require(sum(1 for row in rows for v in row if v and (math.isinf(float(v)) or math.isnan(float(v)))) == 0, "inf/nan found")
        return 1.0
    finally:
        conn.close()

def component_3_recency_percentile_inverted():
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, "SELECT cart_id, hours_since_abandonment, recency_percentile FROM main.mart_ecommerce__recovery_scorecard WHERE hours_since_abandonment IS NOT NULL ORDER BY hours_since_abandonment ASC LIMIT 3")
        for cid, hrs, pct in results:
            require(float(pct) >= 0.5, f"Cart {cid} low hours {hrs} has low percentile {pct}")
        return 1.0
    finally:
        conn.close()

def component_4_recovery_tier_logic():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, "SELECT COUNT(*) FROM main.mart_ecommerce__recovery_scorecard WHERE recovery_tier = 'hot_lead' AND NOT (priority_percentile >= 0.75 AND hours_since_abandonment < 24 AND cart_value > 200)")
        hot = result[0][0]
        require(hot == 0, f"{hot} hot leads not meeting criteria")
        return 1.0
    finally:
        conn.close()

def component_5_conversion_index_bounds():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, "SELECT MIN(conversion_likelihood_index), MAX(conversion_likelihood_index) FROM main.mart_ecommerce__recovery_scorecard")
        min_v, max_v = result[0]
        require(float(min_v) >= -0.01 and float(max_v) <= 100.01, f"Index out of bounds: {min_v}-{max_v}")
        return 1.0
    finally:
        conn.close()

def component_6_device_peer_rank():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, "SELECT device_type, MIN(device_recovery_rank) FROM main.mart_ecommerce__recovery_scorecard WHERE device_type IS NOT NULL GROUP BY device_type")
        for dev, rank in result:
            require(rank == 1, f"Device {dev}: min rank={rank}")
        return 1.0
    finally:
        conn.close()

def component_7_recovery_priority_formula():
    """Validate recovery_priority_score formula: cart_value 40%, item_count 20%, recency 25%, history 15%"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT cart_id, cart_value, item_count, hours_since_abandonment, previous_orders_count, recovery_priority_score
            FROM main.mart_ecommerce__recovery_scorecard LIMIT 20
        """)
        errors = []
        for cid, cv, ic, hrs, po, actual in results:
            cv = float(cv) if cv else 0
            ic = float(ic) if ic else 0
            hrs = float(hrs) if hrs else 0
            po = float(po) if po else 0
            actual = float(actual) if actual else 0
            expected = (
                min(1, cv / 1000.0) * 40 +
                min(1, ic / 10.0) * 20 +
                (1 - min(1, hrs / 168.0)) * 25 +
                min(1, po / 5.0) * 15
            )
            expected = max(0, min(100, expected))
            if abs(actual - expected) > 1.0:
                errors.append(f"Cart {cid}: score={actual:.2f}, expected={expected:.2f}")
        require(len(errors) == 0, f"Priority formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()

def component_8_conversion_index_formula():
    """Validate conversion_likelihood_index formula: cart 30%, history 25%, engagement 25%, recency 20%"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT cart_id, cart_value, previous_orders_count, engagement_level, hours_since_abandonment, conversion_likelihood_index
            FROM main.mart_ecommerce__recovery_scorecard LIMIT 20
        """)
        errors = []
        for cid, cv, po, eng, hrs, actual in results:
            cv = float(cv) if cv else 0
            po = float(po) if po else 0
            eng = float(eng) if eng else 0
            hrs = float(hrs) if hrs else 0
            actual = float(actual) if actual else 0
            expected = (
                min(1, cv / 1000.0) * 30 +
                min(1, po / 10.0) * 25 +
                min(1, eng / 300.0) * 25 +
                (1 - min(1, hrs / 168.0)) * 20
            )
            expected = max(0, min(100, expected))
            if abs(actual - expected) > 1.0:
                errors.append(f"Cart {cid}: index={actual:.2f}, expected={expected:.2f}")
        require(len(errors) == 0, f"Conversion index errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()

def component_9_engagement_level_formula():
    """Validate engagement_level = page_views * session_duration_seconds / 60"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT cart_id, page_views, session_duration_seconds, engagement_level
            FROM main.mart_ecommerce__recovery_scorecard WHERE page_views IS NOT NULL AND session_duration_seconds IS NOT NULL LIMIT 20
        """)
        errors = []
        for cid, pv, sd, actual in results:
            pv = float(pv) if pv else 0
            sd = float(sd) if sd else 0
            actual = float(actual) if actual else 0
            expected = pv * sd / 60.0
            if abs(actual - expected) > 0.01:
                errors.append(f"Cart {cid}: engagement={actual:.2f}, expected={expected:.2f}")
        require(len(errors) == 0, f"Engagement formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()

def component_10_above_device_avg():
    """Validate above_device_avg_value is 1 when cart_value > device average, 0 otherwise"""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            WITH device_avgs AS (
                SELECT device_type, AVG(cart_value) as avg_val FROM main.mart_ecommerce__recovery_scorecard GROUP BY device_type
            )
            SELECT m.cart_id, m.cart_value, m.above_device_avg_value, d.avg_val
            FROM main.mart_ecommerce__recovery_scorecard m
            JOIN device_avgs d ON m.device_type = d.device_type
            WHERE m.device_type IS NOT NULL LIMIT 20
        """)
        errors = []
        for cid, cv, actual, avg_val in result:
            cv = float(cv) if cv else 0
            avg_val = float(avg_val) if avg_val else 0
            expected = 1 if cv > avg_val else 0
            if int(actual) != expected:
                errors.append(f"Cart {cid}: above_avg={actual}, expected={expected} (cv={cv:.2f}, avg={avg_val:.2f})")
        require(len(errors) == 0, f"Above device avg errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()

WEIGHTS = {f"component_{i}_{n}": 1.0 for i, n in enumerate(["models_compile", "no_inf_nan", "recency_percentile_inverted", "recovery_tier_logic", "conversion_index_bounds", "device_peer_rank", "recovery_priority_formula", "conversion_index_formula", "engagement_level_formula", "above_device_avg"], 1)}

def test_solution():
    scores = {n: (globals()[n]() if n in globals() else 0.0) for n in WEIGHTS}
    final = 1.0 if all(s == 1.0 for s in scores.values()) else 0.0
    Path("/logs/verifier").mkdir(parents=True, exist_ok=True)
    Path("/logs/verifier/reward.txt").write_text(str(final))
    # Harbor requires reward.json to be a single-key dict[str, float|int]
    # (harbor.utils.pass_at_k rejects len(rewards) != 1; VerifierResult.rewards
    # is dict[str, float|int]). Emit the overall score as {"reward": ...},
    # matching reward.txt; per-component pass/fail is in the verifier stdout above.
    Path("/logs/verifier/reward.json").write_text(json.dumps({"reward": final_score}))
    assert final == 1.0
