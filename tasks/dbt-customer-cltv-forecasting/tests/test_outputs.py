"""
Verifier for Customer CLTV Forecasting task.
"""
import os
import subprocess

import pytest


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
            schema='analytics',
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')




def run_cmd(cmd, cwd="/app/dbt_project"):
    """Run a shell command and return the result.

    Args:
        cmd: Command string to execute.
        cwd: Working directory for command execution. Defaults to "/app/dbt_project".

    Returns:
        subprocess.CompletedProcess: Result object with returncode, stdout, and stderr.
    """
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:800]}")
    return result


def require(cond, msg):
    """Assert a condition, raising AssertionError with message if false.

    Args:
        cond: Boolean condition to check.
        msg: Error message to raise if condition is false.

    Raises:
        AssertionError: If condition is false.
    """
    if not cond:
        raise AssertionError(msg)


def run_dbt_pipeline():
    """Build reference models and run dbt pipeline for CLTV forecast model.

    This function:
    1. Installs dbt dependencies for the reference transforms project
    2. Builds the int_sales__orders_enriched model
    3. Drops any existing output tables (handling case variations)
    4. Runs the rpt_customer_cltv_forecast model with full refresh

    Raises:
        AssertionError: If any step in the pipeline fails.
    """
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    run_cmd(f"cd {get_dbt_project_dir()} && dbt deps", cwd="/app")
    res = run_cmd(f"cd {get_dbt_project_dir()} && dbt run --select int_sales__orders_enriched", cwd="/app")
    require(res.returncode == 0, "Failed to build int_sales__orders_enriched")

    # drop output first - handle both backends
    if db_type == 'snowflake':
        # For Snowflake, use the connection to drop the table
        try:
            import snowflake.connector
            _conn = snowflake.connector.connect(
                account=os.environ['SNOWFLAKE_ACCOUNT'],
                host=os.environ.get('SNOWFLAKE_HOST') or None,
                user=os.environ['SNOWFLAKE_USER'],
                private_key=get_private_key(),
                database=os.environ['SNOWFLAKE_DATABASE'],
                schema='analytics',
                warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
                role=os.environ.get('SNOWFLAKE_ROLE', None)
            )
            cursor = _conn.cursor()
            cursor.execute("DROP TABLE IF EXISTS analytics.rpt_customer_cltv_forecast")
            _conn.close()
        except Exception:
            pass
    else:
        # DuckDB
        import duckdb as _duckdb
        _conn = _duckdb.connect(os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb'))
        try:
            _conn.execute("DROP TABLE IF EXISTS analytics.rpt_customer_cltv_forecast")
        except Exception:
            pass
        _conn.close()

    res2 = run_cmd("dbt run --select rpt_customer_cltv_forecast --full-refresh", cwd="/app/dbt_project")
    if res2.returncode != 0:
        err = res2.stderr or res2.stdout
        require(False, f"dbt run failed: {err[:1500]}")


@pytest.fixture(scope="module")
def conn():
    """Pytest fixture providing a database connection to the test database.

    This fixture:
    1. Verifies the dbt project directory exists
    2. Runs the dbt pipeline to build the forecast model
    3. Yields a database connection and type
    4. Closes the connection after all tests complete

    Yields:
        tuple: (connection, db_type) pair.

    Raises:
        AssertionError: If project directory is missing or dbt pipeline fails.
    """
    require(os.path.exists("/app/dbt_project"), "dbt_project directory missing")
    run_dbt_pipeline()
    c, db_type = get_db_connection()
    yield c, db_type
    c.close()


def test_schema(conn):
    """Test that the output table has all required columns.

    Verifies that analytics.rpt_customer_cltv_forecast contains all expected
    columns: customer_id, as_of_date, current_lifetime_revenue, current_order_count,
    avg_order_value, days_since_last_order, forecast_3m_revenue, forecast_6m_revenue,
    and forecast_12m_revenue.

    Args:
        conn: Database connection fixture (conn, db_type).

    Raises:
        AssertionError: If any required columns are missing.
    """
    c, db_type = conn
    if db_type == 'snowflake':
        cols = execute_query(c, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = 'analytics'
            AND lower(table_name) = 'rpt_customer_cltv_forecast'
        """)
        col_names = {row[0].lower() for row in cols}
    else:
        cols = execute_query(c, db_type, """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_customer_cltv_forecast')
            ORDER BY cid
        """)
        col_names = {row[0].lower() for row in cols}

    required = {
        "customer_id",
        "as_of_date",
        "current_lifetime_revenue",
        "current_order_count",
        "avg_order_value",
        "days_since_last_order",
        "forecast_3m_revenue",
        "forecast_6m_revenue",
        "forecast_12m_revenue",
    }
    missing = required - col_names
    require(not missing, f"Missing required columns: {missing}")


def test_data_quality(conn):
    """Test data quality constraints on the forecast table.

    Validates:
    - Table contains at least one row
    - No NULL customer_id values
    - All revenue and forecast fields are non-negative
    - Forecast values are non-decreasing (3m <= 6m <= 12m)

    Args:
        conn: Database connection fixture (conn, db_type).

    Raises:
        AssertionError: If any data quality constraint is violated.
    """
    c, db_type = conn
    row = execute_query(c, db_type, """
        SELECT
          COUNT(*) AS total,
          SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END) AS null_ids,
          SUM(CASE WHEN current_lifetime_revenue < 0 THEN 1 ELSE 0 END) AS neg_rev,
          SUM(CASE WHEN forecast_3m_revenue < 0 THEN 1 ELSE 0 END) AS neg_3m,
          SUM(CASE WHEN forecast_6m_revenue < 0 THEN 1 ELSE 0 END) AS neg_6m,
          SUM(CASE WHEN forecast_12m_revenue < 0 THEN 1 ELSE 0 END) AS neg_12m,
          SUM(CASE WHEN forecast_3m_revenue > forecast_6m_revenue OR forecast_6m_revenue > forecast_12m_revenue THEN 1 ELSE 0 END) AS non_mono
        FROM analytics.rpt_customer_cltv_forecast
    """)[0]
    total, null_ids, neg_rev, neg_3m, neg_6m, neg_12m, non_mono = row
    require(total > 0, "No rows produced")
    require(null_ids == 0, f"Found {null_ids} NULL customer_id rows")
    require(neg_rev == 0, f"Found {neg_rev} negative current_lifetime_revenue rows")
    require(neg_3m == 0, f"Found {neg_3m} negative forecast_3m_revenue rows")
    require(neg_6m == 0, f"Found {neg_6m} negative forecast_6m_revenue rows")
    require(neg_12m == 0, f"Found {neg_12m} negative forecast_12m_revenue rows")
    require(non_mono == 0, f"Found {non_mono} rows where forecasts are not non-decreasing")


def test_single_as_of_date(conn):
    """Test that all rows have the same as_of_date value.

    The as_of_date should be consistent across all rows as it represents
    the single point-in-time snapshot used for the forecast.

    Args:
        conn: Database connection fixture (conn, db_type).

    Raises:
        AssertionError: If multiple distinct as_of_date values are found.
    """
    c, db_type = conn
    distinct_dates = execute_scalar(c, db_type,
        "SELECT COUNT(DISTINCT as_of_date) FROM analytics.rpt_customer_cltv_forecast"
    )
    require(distinct_dates == 1, f"Found {distinct_dates} distinct as_of_date values, expected exactly 1")


def test_avg_order_value_consistency(conn):
    """Test that avg_order_value is calculated correctly.

    Verifies that avg_order_value equals current_lifetime_revenue divided by
    current_order_count (with a minimum of 1 to avoid division by zero).
    Allows for small floating-point differences (tolerance: 0.01).

    Args:
        conn: Database connection fixture (conn, db_type).

    Raises:
        AssertionError: If avg_order_value calculation doesn't match expected formula.
    """
    c, db_type = conn
    invalid = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_customer_cltv_forecast
        WHERE ABS(
          avg_order_value - (current_lifetime_revenue / GREATEST(current_order_count, 1))
        ) > 0.01
    """)
    require(invalid == 0, f"Found {invalid} rows where avg_order_value doesn't match current_lifetime_revenue / current_order_count")


def test_reconciliation(conn):
    """Test that total revenue in output matches source data.

    Recalculates total revenue from the source table (int_sales__orders_enriched)
    using the same filters and as_of_date logic, then compares it to the sum
    of current_lifetime_revenue in the forecast table. The difference must be
    within 0.01 tolerance to account for rounding.

    Args:
        conn: Database connection fixture (conn, db_type).

    Raises:
        AssertionError: If total revenue doesn't match within tolerance.
    """
    c, db_type = conn
    # Source aggregates from int_sales__orders_enriched
    src = execute_scalar(c, db_type, """
        WITH orders AS (
          SELECT
            customer_id,
            CAST(ordered_at AS DATE) AS order_date,
            CAST(grand_total AS DECIMAL(18,2)) AS grand_total
          FROM main.int_sales__orders_enriched
          WHERE customer_id IS NOT NULL
            AND ordered_at IS NOT NULL
            AND is_cancelled = false
        ),
        as_of AS (
          SELECT MAX(order_date) AS as_of_date FROM orders
        )
        SELECT
          ROUND(SUM(o.grand_total), 2) AS total_rev
        FROM orders o
        CROSS JOIN as_of a
        WHERE o.order_date <= a.as_of_date
    """)

    out = execute_scalar(c, db_type, """
        SELECT ROUND(SUM(current_lifetime_revenue), 2) AS total_current
        FROM analytics.rpt_customer_cltv_forecast
    """)

    diff = abs(float(src) - float(out))
    require(diff <= 0.01, f"Total current_lifetime_revenue {out} does not match source {src} (diff={diff})")
