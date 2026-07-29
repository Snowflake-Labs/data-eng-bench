"""
Test cases for Customer LTV Fix task.
Supports both DuckDB and Snowflake backends.
"""
import pytest
import subprocess
import os


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


# ============ HELPERS ============


def get_source_table(table_name, db_type):
    """Get the fully qualified source table name based on backend"""
    if db_type == 'snowflake':
        if table_name == 'orders':
            return 'ORDERS.ORDERS'
        elif table_name == 'customers':
            return 'CUSTOMER.CUSTOMERS'
        return f'main.{table_name}'
    else:
        return f'main.{table_name}'


def get_output_table(table_name, db_type):
    """Get the fully qualified output table name"""
    return f'main.{table_name}'


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def db_conn():
    """Create database connection."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


@pytest.fixture(scope="module")
def expected_values(db_conn):
    """Calculate expected values from source data."""
    conn, db_type = db_conn

    orders_table = get_source_table('orders', db_type)
    customers_table = get_source_table('customers', db_type)

    result = execute_query(conn, db_type, f"""
        WITH all_customers AS (
            SELECT customer_id FROM {customers_table}
        ),
        valid_orders AS (
            SELECT
                o.customer_id,
                o.order_id,
                o.grand_total
            FROM {orders_table} o
            INNER JOIN all_customers c ON o.customer_id = c.customer_id
            WHERE o.status NOT IN ('CANCELLED', 'RETURNED')
        ),
        customer_metrics AS (
            SELECT
                customer_id,
                count(distinct order_id) as total_orders,
                round(sum(grand_total), 2) as lifetime_value
            FROM valid_orders
            GROUP BY customer_id
        )
        SELECT
            (SELECT count(*) FROM {customers_table}) as total_customers,
            count(*) as customers_with_orders,
            sum(total_orders) as total_orders,
            round(sum(lifetime_value), 2) as total_ltv,
            count(case when lifetime_value >= 1000 then 1 end) as vip_count,
            count(case when lifetime_value >= 500 and lifetime_value < 1000 then 1 end) as high_value_count,
            count(case when lifetime_value >= 100 and lifetime_value < 500 then 1 end) as medium_value_count,
            count(case when lifetime_value > 0 and lifetime_value < 100 then 1 end) as low_value_count
        FROM customer_metrics
    """)

    row = result[0]
    return {
        'total_customers': int(row[0]),
        'customers_with_orders': int(row[1]),
        'total_orders': int(row[2]),
        'total_ltv': float(row[3]),
        'customers_without_orders': int(row[0]) - int(row[1]),
        'vip_count': int(row[4]),
        'high_value_count': int(row[5]),
        'medium_value_count': int(row[6]),
        'low_value_count': int(row[7]),
        'no_value_count': int(row[0]) - int(row[1])  # customers with no valid orders
    }


# ============================================================
# Phase 1: Table Existence and Structure
# ============================================================

class TestTableStructure:
    """Verify the customer_ltv table exists with correct structure."""

    def test_table_exists(self, db_conn):
        """The customer_ltv table must exist in main schema."""
        conn, db_type = db_conn
        result = execute_scalar(conn, db_type, """
            SELECT count(*)
            FROM information_schema.tables
            WHERE lower(table_name) = 'customer_ltv'
        """)
        assert int(result) >= 1, "Table 'customer_ltv' does not exist"

    def test_required_columns_exist(self, db_conn):
        """All required columns must be present."""
        conn, db_type = db_conn
        required_columns = [
            'customer_id',
            'total_orders',
            'lifetime_value',
            'avg_order_value',
            'first_order_date',
            'last_order_date',
            'value_segment'
        ]

        result = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_name) = 'customer_ltv'
        """)

        actual_columns = [row[0].lower() for row in result]

        for col in required_columns:
            assert col.lower() in actual_columns, f"Required column '{col}' is missing"

    def test_row_count(self, db_conn, expected_values):
        """Should have one row per customer."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table}
        """)
        assert int(result) == expected_values['total_customers'], \
            f"Expected {expected_values['total_customers']} rows, got {result}"

    def test_no_null_customer_ids(self, db_conn):
        """customer_id should never be NULL."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE customer_id IS NULL
        """)
        assert int(result) == 0, f"Found {result} rows with NULL customer_id"

    def test_unique_customer_ids(self, db_conn):
        """Each customer should appear only once."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) - count(distinct customer_id) as duplicates
            FROM {output_table}
        """)
        assert int(result) == 0, f"Found {result} duplicate customer_ids"


# ============================================================
# Phase 2: LTV Calculation Correctness
# ============================================================

class TestLTVCalculation:
    """Verify LTV is calculated correctly (excluding returns)."""

    def test_total_ltv_value(self, db_conn, expected_values):
        """
        Total LTV should match expected value
        (excludes cancelled and returned orders).
        """
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT round(sum(lifetime_value), 2) FROM {output_table}
        """)

        expected = expected_values['total_ltv']
        tolerance = 1.0  # Allow $1 tolerance for rounding

        assert abs(float(result) - expected) <= tolerance, \
            f"Total LTV {result} differs from expected {expected}"

    def test_returns_excluded(self, db_conn):
        """
        LTV should NOT include returned orders.
        Compare total LTV to what it would be if returns were included.
        """
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        orders_table = get_source_table('orders', db_type)

        # Get current LTV
        current_ltv = execute_scalar(conn, db_type, f"""
            SELECT sum(lifetime_value) FROM {output_table}
        """)

        # Get what LTV would be if we included returns
        buggy_ltv = execute_scalar(conn, db_type, f"""
            SELECT sum(grand_total)
            FROM {orders_table}
            WHERE status != 'CANCELLED'
        """)

        # Current LTV should be less than buggy LTV (returns excluded)
        assert float(current_ltv) < float(buggy_ltv), \
            f"LTV {current_ltv} should be less than {buggy_ltv} - returns may not be excluded"

    def test_total_orders_count(self, db_conn, expected_values):
        """Total valid orders should match expected."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT sum(total_orders) FROM {output_table}
        """)

        assert int(result) == expected_values['total_orders'], \
            f"Expected {expected_values['total_orders']} total orders, got {result}"

    def test_customers_with_orders(self, db_conn, expected_values):
        """Correct number of customers should have at least one valid order."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE total_orders > 0
        """)

        assert int(result) == expected_values['customers_with_orders'], \
            f"Expected {expected_values['customers_with_orders']} customers with orders, got {result}"

    def test_customers_without_orders(self, db_conn, expected_values):
        """Correct number of customers should have zero valid orders."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE total_orders = 0
        """)

        assert int(result) == expected_values['customers_without_orders'], \
            f"Expected {expected_values['customers_without_orders']} customers without orders, got {result}"


# ============================================================
# Phase 3: Value Segment Validation
# ============================================================

class TestValueSegments:
    """Verify value segments are correctly assigned."""

    def test_valid_segment_values(self, db_conn):
        """All segments must be one of the valid values."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        valid_segments = ['VIP', 'High Value', 'Medium Value', 'Low Value', 'No Value']

        result = execute_query(conn, db_type, f"""
            SELECT distinct value_segment FROM {output_table}
        """)

        actual_segments = [row[0] for row in result]

        for segment in actual_segments:
            assert segment in valid_segments, f"Invalid segment: {segment}"

    def test_vip_segment_count(self, db_conn, expected_values):
        """VIP count should match expected (LTV >= 1000)."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE value_segment = 'VIP'
        """)

        assert int(result) == expected_values['vip_count'], \
            f"Expected {expected_values['vip_count']} VIP customers, got {result}"

    def test_high_value_segment_count(self, db_conn, expected_values):
        """High Value count should match expected (500 <= LTV < 1000)."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE value_segment = 'High Value'
        """)

        assert int(result) == expected_values['high_value_count'], \
            f"Expected {expected_values['high_value_count']} High Value customers, got {result}"

    def test_medium_value_segment_count(self, db_conn, expected_values):
        """Medium Value count should match expected (100 <= LTV < 500)."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE value_segment = 'Medium Value'
        """)

        assert int(result) == expected_values['medium_value_count'], \
            f"Expected {expected_values['medium_value_count']} Medium Value customers, got {result}"

    def test_low_value_segment_count(self, db_conn, expected_values):
        """Low Value count should match expected (0 < LTV < 100)."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE value_segment = 'Low Value'
        """)

        assert int(result) == expected_values['low_value_count'], \
            f"Expected {expected_values['low_value_count']} Low Value customers, got {result}"

    def test_no_value_segment_count(self, db_conn, expected_values):
        """No Value count should match expected (LTV = 0)."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE value_segment = 'No Value'
        """)

        assert int(result) == expected_values['no_value_count'], \
            f"Expected {expected_values['no_value_count']} No Value customers, got {result}"

    def test_segment_threshold_vip(self, db_conn):
        """All VIP customers should have LTV >= 1000."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table}
            WHERE value_segment = 'VIP' AND lifetime_value < 1000
        """)

        assert int(result) == 0, f"Found {result} VIP customers with LTV < 1000"

    def test_segment_threshold_no_value(self, db_conn):
        """All No Value customers should have LTV = 0."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table}
            WHERE value_segment = 'No Value' AND lifetime_value > 0
        """)

        assert int(result) == 0, f"Found {result} No Value customers with LTV > 0"


# ============================================================
# Phase 4: Data Quality Checks
# ============================================================

class TestDataQuality:
    """Additional data quality validations."""

    def test_no_negative_ltv(self, db_conn):
        """LTV should never be negative."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE lifetime_value < 0
        """)

        assert int(result) == 0, f"Found {result} customers with negative LTV"

    def test_no_negative_orders(self, db_conn):
        """Total orders should never be negative."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table} WHERE total_orders < 0
        """)

        assert int(result) == 0, f"Found {result} customers with negative order count"

    def test_avg_order_value_consistency(self, db_conn):
        """avg_order_value should equal lifetime_value / total_orders."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table}
            WHERE total_orders > 0
            AND abs(avg_order_value - (lifetime_value / total_orders)) > 1
        """)

        assert int(result) == 0, f"Found {result} rows with inconsistent avg_order_value"

    def test_zero_orders_zero_avg(self, db_conn):
        """Customers with zero orders should have zero avg_order_value."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table}
            WHERE total_orders = 0 AND avg_order_value != 0
        """)

        assert int(result) == 0, f"Found {result} zero-order customers with non-zero avg"

    def test_date_consistency(self, db_conn):
        """first_order_date should be <= last_order_date."""
        conn, db_type = db_conn
        output_table = get_output_table('customer_ltv', db_type)
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {output_table}
            WHERE first_order_date > last_order_date
        """)

        assert int(result) == 0, f"Found {result} rows where first > last order date"
