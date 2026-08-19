"""
Tests for dbt_fix_timezone_sales task
"""
import os
import subprocess
import pytest
from datetime import datetime, timedelta


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
    """Execute a query and return results"""
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


# ============ HELPERS ============


def _get_parse_timestamp_sql(db_type, col):
    """Return a CASE expression that parses mixed-format timestamps for a given column."""
    if db_type == 'snowflake':
        return f"""
CASE
    WHEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'YYYY-MM-DD HH24:MI:SS') IS NOT NULL THEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'YYYY-MM-DD HH24:MI:SS')
    WHEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'YYYY-MM-DD') IS NOT NULL THEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'YYYY-MM-DD')
    WHEN REGEXP_LIKE(CAST({col} AS VARCHAR), '^[0-9]{{8}}$') THEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'YYYYMMDD')
    WHEN REGEXP_LIKE(CAST({col} AS VARCHAR), '^[0-9]{{1,2}}/[0-9]{{1,2}}/[0-9]{{4}} [0-9]{{1,2}}:[0-9]{{2}}') THEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'MM/DD/YYYY HH24:MI:SS')
    WHEN REGEXP_LIKE(CAST({col} AS VARCHAR), '^[0-9]{{1,2}}/[0-9]{{1,2}}/[0-9]{{4}}$') THEN TRY_TO_TIMESTAMP(CAST({col} AS VARCHAR), 'MM/DD/YYYY')
    WHEN TRY_TO_NUMBER(CAST({col} AS VARCHAR), 38, 6) IS NOT NULL THEN TO_TIMESTAMP_NTZ(TRY_TO_NUMBER(CAST({col} AS VARCHAR), 38, 6))
    ELSE NULL
END
"""
    else:
        return f"""
CASE
    WHEN TRY_CAST({col} AS TIMESTAMP) IS NOT NULL THEN TRY_CAST({col} AS TIMESTAMP)
    WHEN CAST({col} AS VARCHAR) ~ '^[0-9]{{4}}[0-9]{{2}}[0-9]{{2}}$' THEN TRY_CAST(strptime(CAST({col} AS VARCHAR), '%Y%m%d') AS TIMESTAMP)
    WHEN CAST({col} AS VARCHAR) ~ '^[0-9]{{1,2}}/[0-9]{{1,2}}/[0-9]{{4}} [0-9]{{1,2}}:[0-9]{{2}}' THEN TRY_CAST(strptime(CAST({col} AS VARCHAR), '%m/%d/%Y %H:%M:%S') AS TIMESTAMP)
    WHEN CAST({col} AS VARCHAR) ~ '^[0-9]{{1,2}}/[0-9]{{1,2}}/[0-9]{{4}}' THEN TRY_CAST(strptime(CAST({col} AS VARCHAR), '%m/%d/%Y') AS TIMESTAMP)
    WHEN TRY_CAST({col} AS DOUBLE) IS NOT NULL THEN to_timestamp(TRY_CAST({col} AS DOUBLE))
    ELSE NULL
END
"""


def run_cmd(cmd, cwd=None):
    """Run a shell command in the dbt project dir and return the result."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[-2000:] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[-1000:]}")
    return result


@pytest.fixture(scope="module", autouse=True)
def rebuild_model():
    """Rebuild the model under test from the agent's code before verifying.

    Without this the verifier reads the int_sales__orders_enriched view
    definition that was materialized when the container image was built,
    so it would award full reward for zero agent work (pass-by-default).
    Rebuilding forces the verifier to measure the agent's actual model.
    """
    deps = run_cmd("dbt deps")
    assert deps.returncode == 0, f"dbt deps failed:\n{deps.stdout}\n{deps.stderr}"
    run = run_cmd("dbt run --select int_sales__orders_enriched")
    assert run.returncode == 0, f"dbt run failed:\n{run.stdout}\n{run.stderr}"


@pytest.fixture(scope="module")
def db_conn(rebuild_model):
    """Database connection fixture (depends on rebuild_model so the agent's
    model is materialized before any assertions run)."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


@pytest.fixture(scope="module")
def test_order_ids(db_conn):
    """
    Fetch sample order IDs from both SAP and POS systems for testing
    """
    conn, db_type = db_conn

    def sample(system):
        rows = execute_query(conn, db_type, f"""
            SELECT DISTINCT order_id
            FROM main.int_sales__orders_enriched
            WHERE source_system = '{system}'
            AND ordered_at IS NOT NULL
            ORDER BY order_id
            LIMIT 5
        """)
        return [row[0] for row in rows]

    # Sample each system independently. A previous single-query LIMIT 20 ordered
    # by source_system returned only POS rows (POS < SAP), leaving SAP empty and
    # silently disabling the cross-system timezone-alignment assertion.
    return {
        'SAP': sample('SAP'),
        'POS': sample('POS'),
    }


def test_int_sales_orders_enriched_exists(db_conn):
    """Test that int_sales__orders_enriched view exists"""
    conn, db_type = db_conn
    count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE lower(table_name) = 'int_sales__orders_enriched'
        AND lower(table_schema) = 'main'
    """)

    assert int(count) >= 1, "int_sales__orders_enriched view does not exist"


def test_int_sales_has_data(db_conn):
    """Test that int_sales__orders_enriched has data"""
    conn, db_type = db_conn
    count = execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main.int_sales__orders_enriched")
    assert int(count) > 0, "int_sales__orders_enriched view is empty"


def test_sap_timestamps_handling(db_conn, test_order_ids):
    """
    Verify SAP timestamps are adjusted relative to staging.
    Accepts either: unchanged OR -5 hours (both are valid timezone corrections)
    """
    conn, db_type = db_conn
    parse_ts = _get_parse_timestamp_sql(db_type, 'ordered_at')

    for order_id in test_order_ids['SAP']:
        # Get timestamp from int_sales__orders_enriched
        enriched_ts = execute_query(conn, db_type, f"""
            SELECT ordered_at
            FROM main.int_sales__orders_enriched
            WHERE order_id = '{order_id}'
        """)

        # Get original timestamp from staging (parsed)
        staging_ts = execute_query(conn, db_type, f"""
            SELECT
                {parse_ts} as parsed_ts
            FROM main.stg_sap__vbak
            WHERE order_id = '{order_id}'
        """)

        if enriched_ts and staging_ts and enriched_ts[0][0] and staging_ts[0][0]:
            time_diff = execute_scalar(conn, db_type, f"""
                SELECT DATEDIFF('hour', CAST('{staging_ts[0][0]}' AS TIMESTAMP), CAST('{enriched_ts[0][0]}' AS TIMESTAMP))
            """)

            # Accept either: SAP unchanged (0) or moved back (-5)
            assert int(time_diff) in [0, -5], \
                f"Order {order_id}: SAP timestamp diff is {time_diff} hours, expected 0 or -5"


def test_timezone_alignment_consistency(db_conn, test_order_ids):
    """
    Test that POS and SAP timestamps are aligned consistently (5-hour difference corrected).
    This verifies the core fix: both systems should now be in the same timezone.
    Matches rows by order_id to avoid non-deterministic LIMIT 1 comparisons.
    """
    conn, db_type = db_conn
    parse_ts_ordered = _get_parse_timestamp_sql(db_type, 'ordered_at')

    pos_diffs = []
    sap_diffs = []

    # Check POS orders: enriched vs staging, matched by order_id
    for order_id in test_order_ids.get('POS', []):
        enriched_ts = execute_query(conn, db_type, f"""
            SELECT ordered_at
            FROM main.int_sales__orders_enriched
            WHERE order_id = '{order_id}'
        """)
        staging_ts = execute_query(conn, db_type, f"""
            SELECT {parse_ts_ordered} as parsed_ts
            FROM main.stg_pos__transactions
            WHERE order_id = '{order_id}'
        """)
        if enriched_ts and staging_ts and enriched_ts[0][0] and staging_ts[0][0]:
            diff = int(execute_scalar(conn, db_type, f"""
                SELECT DATEDIFF('hour', CAST('{staging_ts[0][0]}' AS TIMESTAMP), CAST('{enriched_ts[0][0]}' AS TIMESTAMP))
            """))
            pos_diffs.append(diff)

    # Check SAP orders: enriched vs staging, matched by order_id
    for order_id in test_order_ids.get('SAP', []):
        enriched_ts = execute_query(conn, db_type, f"""
            SELECT ordered_at
            FROM main.int_sales__orders_enriched
            WHERE order_id = '{order_id}'
        """)
        staging_ts = execute_query(conn, db_type, f"""
            SELECT {parse_ts_ordered} as parsed_ts
            FROM main.stg_sap__vbak
            WHERE order_id = '{order_id}'
        """)
        if enriched_ts and staging_ts and enriched_ts[0][0] and staging_ts[0][0]:
            diff = int(execute_scalar(conn, db_type, f"""
                SELECT DATEDIFF('hour', CAST('{staging_ts[0][0]}' AS TIMESTAMP), CAST('{enriched_ts[0][0]}' AS TIMESTAMP))
            """))
            sap_diffs.append(diff)

    assert pos_diffs or sap_diffs, "No matched order_id timestamps found for timezone check"

    if pos_diffs and sap_diffs:
        # Use median diff for each system to be robust
        pos_diff = sorted(pos_diffs)[len(pos_diffs) // 2]
        sap_diff = sorted(sap_diffs)[len(sap_diffs) // 2]
        total_adjustment = pos_diff - sap_diff
        assert abs(total_adjustment - 5) < 1, \
            f"Timezone adjustment incorrect: POS moved {pos_diff}h, SAP moved {sap_diff}h, total={total_adjustment}h (expected 5h difference)"


def test_daily_aggregation_consistency(db_conn):
    """
    Test that daily sales aggregations work correctly
    """
    conn, db_type = db_conn
    result = execute_query(conn, db_type, """
        SELECT
            date_trunc('day', ordered_at) as sales_day,
            COUNT(*) as order_count,
            SUM(grand_total) as daily_total
        FROM main.int_sales__orders_enriched
        WHERE ordered_at IS NOT NULL
        AND is_cancelled = 0
        GROUP BY date_trunc('day', ordered_at)
        HAVING COUNT(*) > 0
        ORDER BY date_trunc('day', ordered_at) DESC
        LIMIT 10
    """)

    assert len(result) > 0, "No daily aggregations found"

    for row in result:
        sales_day, order_count, daily_total = row
        assert int(order_count) > 0, f"Day {sales_day} has no orders"
        assert float(daily_total) >= 0, f"Day {sales_day} has negative total"


def test_all_timestamps_have_time_component(db_conn):
    """Test that timestamps weren't accidentally truncated to dates"""
    conn, db_type = db_conn
    midnight_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.int_sales__orders_enriched
        WHERE ordered_at IS NOT NULL
        AND EXTRACT(hour FROM ordered_at) = 0
        AND EXTRACT(minute FROM ordered_at) = 0
        AND EXTRACT(second FROM ordered_at) = 0
    """))

    total_orders = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.int_sales__orders_enriched WHERE ordered_at IS NOT NULL
    """))

    midnight_ratio = midnight_count / total_orders if total_orders > 0 else 0
    assert midnight_ratio < 0.9, \
        f"Timestamps appear truncated ({midnight_ratio:.1%}) at midnight"


def test_source_system_distribution(db_conn):
    """Test that both SAP and POS orders exist"""
    conn, db_type = db_conn
    result = execute_query(conn, db_type, """
        SELECT
            source_system,
            COUNT(*) as count
        FROM main.int_sales__orders_enriched
        GROUP BY source_system
    """)

    systems = {row[0]: int(row[1]) for row in result}
    assert 'SAP' in systems, "No SAP orders found"
    assert 'POS' in systems, "No POS orders found"
    assert systems['SAP'] > 0, "SAP order count is 0"
    assert systems['POS'] > 0, "POS order count is 0"


def test_no_null_timestamps_for_completed_orders(db_conn):
    """Test that delivered orders always have delivered_at timestamp (ordered_at can be NULL in source)"""
    conn, db_type = db_conn
    # Only check delivered_at - ordered_at can be NULL in source data (data quality issue)
    count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.int_sales__orders_enriched
        WHERE is_delivered = 1
          AND delivered_at IS NULL
    """))

    assert count == 0, f"Found {count} delivered orders with NULL delivered_at"


def test_timestamp_ordering(db_conn):
    """Test that timestamp ordering makes sense (ordered < shipped < delivered)"""
    conn, db_type = db_conn
    shipped_before_ordered = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.int_sales__orders_enriched
        WHERE ordered_at IS NOT NULL
        AND shipped_at IS NOT NULL
        AND shipped_at < ordered_at
    """))

    assert shipped_before_ordered == 0, "Found orders where shipped_at is before ordered_at"

    delivered_before_shipped = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.int_sales__orders_enriched
        WHERE shipped_at IS NOT NULL
        AND delivered_at IS NOT NULL
        AND delivered_at < shipped_at
    """))

    assert delivered_before_shipped == 0, "Found orders where delivered_at is before shipped_at"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist"""
    conn, db_type = db_conn
    required_columns = [
        'order_id', 'order_number', 'customer_id', 'source_system',
        'grand_total', 'ordered_at', 'is_cancelled', 'is_delivered'
    ]

    result = execute_query(conn, db_type, """
        SELECT lower(column_name)
        FROM information_schema.columns
        WHERE lower(table_name) = 'int_sales__orders_enriched'
        AND lower(table_schema) = 'main'
    """)

    existing_columns = [row[0] for row in result]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing. Available: {existing_columns}"
