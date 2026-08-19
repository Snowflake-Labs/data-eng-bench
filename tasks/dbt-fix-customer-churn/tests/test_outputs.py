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


@pytest.fixture(scope="module")
def db_conn():
    """Create a connection to the database (DuckDB or Snowflake)"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ============ TESTS ============


def test_previous_order_belongs_to_same_customer(db_conn):
    """Test that LAG values are from the same customer"""
    conn, db_type = db_conn

    mismatched = execute_scalar(conn, db_type, """
        WITH activity_data AS (
            SELECT
                a.customer_id,
                a.order_id,
                a.order_date,
                a.previous_order_date
            FROM main.fct_customer_activity a
            WHERE a.previous_order_date IS NOT NULL
        ),
        prev_orders AS (
            SELECT DISTINCT
                o2.customer_id,
                CAST(o2.ORDERED_AT AS DATE) AS order_date
            FROM main.stg_orders__orders o2
        )
        SELECT COUNT(*)
        FROM activity_data a
        LEFT JOIN prev_orders p ON p.order_date = a.previous_order_date
            AND p.customer_id = a.customer_id
        WHERE p.customer_id IS NULL
    """)

    assert mismatched == 0, \
        f"Found {mismatched} records where previous_order_date doesn't belong to same customer"


def test_first_order_has_null_previous_date(db_conn):
    """Test that each customer's first order has NULL previous_order_date"""
    conn, db_type = db_conn
    param_placeholder = '%s' if db_type == 'snowflake' else '?'

    first_orders = execute_query(conn, db_type, """
        SELECT
            customer_id,
            MIN(cast(ORDERED_AT as date)) as first_order_date
        FROM main.stg_orders__orders
        GROUP BY customer_id
    """)

    errors = []
    for customer_id, first_order_date in first_orders:
        query = f"""
            SELECT previous_order_date
            FROM main.fct_customer_activity
            WHERE customer_id = {param_placeholder}
              AND order_date = {param_placeholder}
            ORDER BY order_id ASC
            LIMIT 1
        """
        result = execute_query(conn, db_type, query, [customer_id, first_order_date])

        if result and result[0][0] is not None:
            errors.append(f"Customer {customer_id} first order has non-NULL previous_order_date")

    assert len(errors) == 0, f"First order errors: {'; '.join(errors[:5])}"


def test_days_calculation_accurate(db_conn):
    """Test that days_since_last_order matches manual calculation"""
    conn, db_type = db_conn
    param_placeholder = '%s' if db_type == 'snowflake' else '?'

    samples = execute_query(conn, db_type, """
        SELECT
            customer_id,
            order_date,
            previous_order_date,
            days_since_last_order
        FROM main.fct_customer_activity
        WHERE previous_order_date IS NOT NULL
        LIMIT 100
    """)

    errors = []
    for customer_id, order_date, prev_date, days in samples:
        query = f"""
            SELECT DATEDIFF('day', {param_placeholder}::DATE, {param_placeholder}::DATE)
        """
        expected_days = execute_scalar(conn, db_type, query, [prev_date, order_date])

        if days != expected_days:
            errors.append(
                f"Customer {customer_id}: reported {days} days, expected {expected_days}"
            )

    assert len(errors) == 0, f"Days calculation errors: {'; '.join(errors[:5])}"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist"""
    conn, db_type = db_conn

    required_columns = [
        'customer_id', 'email', 'order_id', 'order_date',
        'previous_order_date', 'days_since_last_order', 'is_reactivated_order'
    ]

    if db_type == 'snowflake':
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM main.fct_customer_activity LIMIT 1")
        existing_columns = [col[0].lower() for col in cursor.description]
    else:
        result = conn.execute("SELECT * FROM main.fct_customer_activity LIMIT 1")
        existing_columns = [col[0].lower() for col in result.description]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing"


def test_all_orders_present(db_conn):
    """Test that all orders are in the activity table"""
    conn, db_type = db_conn

    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.stg_orders__orders
    """)

    report_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_customer_activity
    """)

    assert report_count == source_count, \
        f"Order count mismatch: report={report_count}, source={source_count}"


def test_no_negative_days(db_conn):
    """Test that days_since_last_order is never negative"""
    conn, db_type = db_conn

    negative_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_customer_activity
        WHERE days_since_last_order < 0
    """)

    assert negative_count == 0, f"Found {negative_count} records with negative days"


def test_reactivation_logic_correct(db_conn):
    """Test that reactivation flag matches days threshold"""
    conn, db_type = db_conn

    # Use NOT and direct boolean comparison that works on both DuckDB and Snowflake
    mismatched = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_customer_activity
        WHERE (days_since_last_order > 90 AND NOT is_reactivated_order)
           OR (days_since_last_order <= 90 AND is_reactivated_order)
           OR (days_since_last_order IS NULL AND is_reactivated_order)
    """)

    assert mismatched == 0, \
        f"Found {mismatched} records with incorrect reactivation flag"


def test_customer_order_sequence(db_conn):
    """Test that orders are in sequence per customer"""
    conn, db_type = db_conn

    invalid_sequence = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_customer_activity
        WHERE previous_order_date IS NOT NULL
          AND previous_order_date > order_date
    """)

    assert invalid_sequence == 0, \
        f"Found {invalid_sequence} records where previous_order_date > order_date"
