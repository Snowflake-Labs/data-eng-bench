import pytest
import os
import subprocess


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


# ============ TESTS ============


@pytest.fixture(scope="module")
def db_conn():
    """Create a database connection"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_day_0_retention_is_100_percent(db_conn):
    """Test that day 0 retention is always 100% (all customers ordered on their cohort date)"""
    conn, db_type = db_conn
    invalid = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts
        WHERE ABS(day_0_retention - 1.0) > 0.001
    """)

    assert int(invalid) == 0, \
        f"Found {invalid} cohorts where day_0_retention != 100%"


def test_retention_decreases_over_time(db_conn):
    """Test that retention rates don't increase over time"""
    conn, db_type = db_conn
    invalid = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts
        WHERE day_7_retention > day_0_retention + 0.001
           OR day_30_retention > day_7_retention + 0.001
           OR day_90_retention > day_30_retention + 0.001
    """)

    assert int(invalid) == 0, \
        f"Found {invalid} cohorts with increasing retention over time"


def test_customer_counts_cumulative(db_conn):
    """Test that customer counts are cumulative (later periods include earlier)"""
    conn, db_type = db_conn
    invalid = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts
        WHERE day_7_customers < day_0_customers
           OR day_30_customers < day_7_customers
           OR day_90_customers < day_30_customers
    """)

    assert int(invalid) == 0, \
        f"Found {invalid} cohorts where customer counts aren't cumulative"


def test_cohort_size_matches_day_0(db_conn):
    """Test that cohort size equals day 0 customers"""
    conn, db_type = db_conn
    invalid = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts
        WHERE cohort_size != day_0_customers
    """)

    assert int(invalid) == 0, \
        f"Found {invalid} cohorts where cohort_size != day_0_customers"


def test_retention_rates_between_0_and_1(db_conn):
    """Test that all retention rates are valid percentages"""
    conn, db_type = db_conn
    invalid = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts
        WHERE day_0_retention < 0 OR day_0_retention > 1
           OR day_7_retention < 0 OR day_7_retention > 1
           OR day_30_retention < 0 OR day_30_retention > 1
           OR day_90_retention < 0 OR day_90_retention > 1
    """)

    assert int(invalid) == 0, \
        f"Found {invalid} cohorts with invalid retention rates (outside 0-1 range)"


def test_all_cohorts_have_customers(db_conn):
    """Test that every cohort has at least one customer"""
    conn, db_type = db_conn
    empty_cohorts = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts
        WHERE cohort_size = 0
    """)

    assert int(empty_cohorts) == 0, \
        f"Found {empty_cohorts} empty cohorts"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist"""
    conn, db_type = db_conn
    required_columns = [
        'cohort_date', 'cohort_size', 'day_0_customers', 'day_7_customers',
        'day_30_customers', 'day_90_customers', 'day_0_retention', 'day_7_retention',
        'day_30_retention', 'day_90_retention'
    ]

    result = execute_query(conn, db_type, """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_name) = 'rpt_daily_cohorts'
          AND lower(table_schema) = 'main'
    """)

    existing_columns = [row[0].lower() for row in result]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing"


def test_cohort_dates_are_unique(db_conn):
    """Test that each cohort date appears only once"""
    conn, db_type = db_conn
    duplicates = execute_query(conn, db_type, """
        SELECT cohort_date, COUNT(*)
        FROM main.rpt_daily_cohorts
        GROUP BY 1
        HAVING COUNT(*) > 1
    """)

    assert len(duplicates) == 0, \
        f"Found {len(duplicates)} duplicate cohort dates"


def test_total_cohort_size_matches_customers(db_conn):
    """Test that sum of cohort sizes roughly matches unique customers"""
    conn, db_type = db_conn
    cohort_total = execute_scalar(conn, db_type, """
        SELECT SUM(cohort_size)
        FROM main.rpt_daily_cohorts
    """)

    customer_total = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT customer_id)
        FROM main.stg_orders__orders
    """)

    cohort_total = int(cohort_total)
    customer_total = int(customer_total)

    # Allow small tolerance for edge cases
    tolerance = max(customer_total * 0.01, 1)
    assert abs(cohort_total - customer_total) <= tolerance, \
        f"Cohort size mismatch: cohorts={cohort_total}, customers={customer_total}"


def test_cohort_date_is_first_order_date(db_conn):
    """Test that cohort_date matches the minimum order date for customers in that cohort"""
    conn, db_type = db_conn
    mismatched = execute_scalar(conn, db_type, """
        WITH actual_first_orders AS (
            SELECT
                CAST(ORDERED_AT AS DATE) as order_date,
                customer_id
            FROM main.stg_orders__orders
        ),
        customer_first_dates AS (
            SELECT
                customer_id,
                MIN(order_date) as first_order_date
            FROM actual_first_orders
            GROUP BY customer_id
        ),
        cohort_counts AS (
            SELECT
                first_order_date,
                COUNT(DISTINCT customer_id) as actual_count
            FROM customer_first_dates
            GROUP BY first_order_date
        )
        SELECT COUNT(*)
        FROM main.rpt_daily_cohorts rc
        LEFT JOIN cohort_counts cc ON rc.cohort_date = cc.first_order_date
        WHERE cc.first_order_date IS NULL
           OR ABS(rc.cohort_size - cc.actual_count) > 1
    """)

    assert int(mismatched) == 0, \
        f"Found {mismatched} cohorts where cohort_date/size doesn't match actual first order dates"


def test_one_row_per_cohort_date(db_conn):
    """Test that output has multiple distinct cohort dates (not a single fabricated row)"""
    conn, db_type = db_conn
    cohort_count = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT cohort_date)
        FROM main.rpt_daily_cohorts
    """)

    # Should have multiple cohort dates if data is real
    assert int(cohort_count) > 1, \
        f"Only {cohort_count} cohort date(s) found - expected multiple cohorts"
