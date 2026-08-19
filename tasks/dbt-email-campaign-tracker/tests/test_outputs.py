"""
Test verifier for dbt-email-campaign-tracker task.
Supports both DuckDB and Snowflake backends.
"""
import subprocess
import math
import json
import os
import pytest
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
    """Create a database connection based on DB_TYPE environment variable.
    Returns (conn, db_type) tuple."""
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
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
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
        # DuckDB
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


# ============ HELPERS ============

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


def query_table(table_name, schema_list=None):
    """Query a table trying multiple schemas."""
    if schema_list is None:
        schema_list = ['main', 'analytics', 'marts', 'marketing']
    conn, db_type = get_db_connection()
    try:
        for schema in schema_list:
            try:
                rows = execute_query(conn, db_type, f"SELECT * FROM {schema}.{table_name}")
                return rows, db_type
            except Exception:
                continue
        raise Exception(f"{table_name} not found in schemas: {schema_list}")
    finally:
        conn.close()


def require(condition, message):
    """Assert a condition is true, raising AssertionError with the given message if not."""
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Models Compile ============

def component_1_models_compile():
    """Verify all three dbt models compile and run successfully."""
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    result = run_cmd("dbt run -s stg_marketing__email_metrics int_marketing__email_performance mart_marketing__email_scorecard")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """Check that rate columns and scores contain no inf/nan values."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['main', 'analytics', 'marts', 'marketing']:
            try:
                rows = execute_query(conn, db_type, f"""
                    SELECT delivery_rate, open_rate, click_rate, engagement_score, campaign_effectiveness_index
                    FROM {schema}.mart_marketing__email_scorecard
                """)
                break
            except Exception:
                continue
        else:
            raise Exception("mart_marketing__email_scorecard not found")

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None:
                    fval = float(val)
                    if math.isinf(fval) or math.isnan(fval):
                        inf_nan_count += 1

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Engagement Score Bounds ============

def component_3_engagement_score_bounds():
    """Validate engagement_score stays within 0-100 range (with 0.01 tolerance)."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['main', 'analytics', 'marts', 'marketing']:
            try:
                bounds = execute_query(conn, db_type, f"""
                    SELECT MIN(engagement_score), MAX(engagement_score)
                    FROM {schema}.int_marketing__email_performance
                """)
                bounds = bounds[0]
                break
            except Exception:
                continue
        else:
            raise Exception("int_marketing__email_performance not found")

        min_val = float(bounds[0]) if bounds[0] is not None else 0
        max_val = float(bounds[1]) if bounds[1] is not None else 0

        require(min_val >= -0.01, f"engagement_score below 0: {min_val}")
        require(max_val <= 100.01, f"engagement_score above 100: {max_val}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Fatigue Logic ============

def component_4_fatigue_logic():
    """Verify fatigue_indicator=1 only when criteria met: open_rate < avg*0.70 AND emails >= 4."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['main', 'analytics', 'marts', 'marketing']:
            try:
                result = execute_query(conn, db_type, f"""
                    SELECT COUNT(*)
                    FROM {schema}.int_marketing__email_performance
                    WHERE fatigue_indicator = 1
                      AND NOT (open_rate < avg_segment_open_rate * 0.70 AND emails_sent_last_30d >= 4)
                """)
                fatigued = int(result[0][0])
                break
            except Exception:
                continue
        else:
            raise Exception("int_marketing__email_performance not found")

        require(fatigued == 0, f"Found {fatigued} fatigued rows not meeting criteria")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Effectiveness Index Bounds ============

def component_5_effectiveness_index_bounds():
    """Validate campaign_effectiveness_index stays within 0-100 range (with 0.01 tolerance)."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['main', 'analytics', 'marts', 'marketing']:
            try:
                bounds = execute_query(conn, db_type, f"""
                    SELECT MIN(campaign_effectiveness_index), MAX(campaign_effectiveness_index)
                    FROM {schema}.mart_marketing__email_scorecard
                """)
                bounds = bounds[0]
                break
            except Exception:
                continue
        else:
            raise Exception("mart_marketing__email_scorecard not found")

        min_val = float(bounds[0]) if bounds[0] is not None else 0
        max_val = float(bounds[1]) if bounds[1] is not None else 0

        require(min_val >= -0.01, f"campaign_effectiveness_index below 0: {min_val}")
        require(max_val <= 100.01, f"campaign_effectiveness_index above 100: {max_val}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Segment Peer Rank ============

def component_6_segment_peer_rank():
    """Verify each segment has at least one row with rank=1 (proper partitioning)."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['main', 'analytics', 'marts', 'marketing']:
            try:
                result = execute_query(conn, db_type, f"""
                    SELECT segment_name, MIN(segment_performance_rank) as min_rank
                    FROM {schema}.mart_marketing__email_scorecard
                    WHERE segment_name IS NOT NULL
                    GROUP BY segment_name
                """)
                break
            except Exception:
                continue
        else:
            raise Exception("mart_marketing__email_scorecard not found")

        for row in result:
            seg = row[0]
            min_rank = int(row[1])
            require(min_rank == 1, f"Segment '{seg}': min rank={min_rank}, expected 1")

        return 1.0
    finally:
        conn.close()


WEIGHTS = {
    "component_1_models_compile": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_engagement_score_bounds": 1.0,
    "component_4_fatigue_logic": 1.0,
    "component_5_effectiveness_index_bounds": 1.0,
    "component_6_segment_peer_rank": 1.0,
}


def test_solution():
    """Run all email campaign tracker verification components and assert all pass."""
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
