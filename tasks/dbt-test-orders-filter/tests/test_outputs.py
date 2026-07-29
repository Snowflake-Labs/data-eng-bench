"""
Test cases for Sales Report Data Quality Fix task
"""
import subprocess
import os
import re
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


def get_orders_source(db_type):
    """Return the correct source table for orders depending on db type."""
    if db_type == 'snowflake':
        return 'main.stg_orders__orders'
    return 'main.orders'


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def db():
    """Create database connection."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


@pytest.fixture(scope="module")
def expected_values(db):
    """Calculate expected values from source data."""
    conn, db_type = db
    orders_src = get_orders_source(db_type)
    if db_type == 'snowflake':
        flag_is_false = "UPPER(CAST({col} AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')"
        flag_is_true = "UPPER(CAST({col} AS VARCHAR)) IN ('1','TRUE','T','Y','YES')"
        prod_where = " AND ".join(
            f"({flag_is_false.format(col=c)} OR {c} IS NULL)"
            for c in ['test_order_flag', 'sample_order_flag', 'internal_order_flag']
        )
        nonprod_where = " OR ".join(
            flag_is_true.format(col=c)
            for c in ['test_order_flag', 'sample_order_flag', 'internal_order_flag']
        )
    else:
        prod_where = ("coalesce(test_order_flag, false) = false"
                      " AND coalesce(sample_order_flag, false) = false"
                      " AND coalesce(internal_order_flag, false) = false")
        nonprod_where = ("coalesce(test_order_flag, false) = true"
                         " OR coalesce(sample_order_flag, false) = true"
                         " OR coalesce(internal_order_flag, false) = true")

    result = execute_query(conn, db_type, f"""
        SELECT
            count(*) as total_production_orders,
            round(sum(grand_total), 2) as total_revenue,
            count(distinct customer_id) as unique_customers
        FROM {orders_src}
        WHERE {prod_where}
    """)

    row = result[0]

    # Count non-production orders for verification
    non_prod = execute_scalar(conn, db_type, f"""
        SELECT count(*)
        FROM {orders_src}
        WHERE {nonprod_where}
    """)

    return {
        'total_production_orders': row[0],
        'total_revenue': float(row[1]),
        'unique_customers': row[2],
        'non_production_orders': non_prod
    }


#
# Phase 1: Table Existence and Structure
#

class TestTableStructure:
    """Verify the production_sales table exists with correct structure."""

    def test_table_exists(self, db):
        """The production_sales table must exist in main schema."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*)
            FROM information_schema.tables
            WHERE lower(table_name) = 'production_sales'
        """)
        assert result >= 1, "Table 'production_sales' does not exist"

    def test_required_columns_exist(self, db):
        """All required columns must be present."""
        conn, db_type = db
        required_columns = [
            'order_id',
            'customer_id',
            'order_date',
            'grand_total',
            'status'
        ]

        result = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_name) = 'production_sales'
        """)

        actual_columns = [row[0].lower() for row in result]

        for col in required_columns:
            assert col.lower() in actual_columns, f"Required column '{col}' is missing"

    def test_row_count(self, db, expected_values):
        """Should have correct number of production orders."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*) FROM main.production_sales
        """)
        assert result == expected_values['total_production_orders'], \
            f"Expected {expected_values['total_production_orders']} rows, got {result}"

    def test_no_null_order_ids(self, db):
        """order_id should never be NULL."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*) FROM main.production_sales WHERE order_id IS NULL
        """)
        assert result == 0, f"Found {result} rows with NULL order_id"

    def test_unique_order_ids(self, db):
        """Each order should appear only once."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*) - count(distinct order_id) as duplicates
            FROM main.production_sales
        """)
        assert result == 0, f"Found {result} duplicate order_ids"


#
# Phase 2: Test Order Filtering
#

class TestOrderFiltering:
    """Verify non-production orders are excluded."""

    def test_no_test_orders(self, db):
        """No test orders should be in production_sales."""
        conn, db_type = db
        orders_src = get_orders_source(db_type)
        if db_type == 'snowflake':
            flag_check = "UPPER(CAST(o.test_order_flag AS VARCHAR)) IN ('1','TRUE','T','Y','YES')"
        else:
            flag_check = "o.test_order_flag = true"
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*)
            FROM main.production_sales ps
            JOIN {orders_src} o ON ps.order_id = o.order_id
            WHERE {flag_check}
        """)
        assert result == 0, f"Found {result} test orders in production_sales"

    def test_no_sample_orders(self, db):
        """No sample orders should be in production_sales."""
        conn, db_type = db
        orders_src = get_orders_source(db_type)
        if db_type == 'snowflake':
            flag_check = "UPPER(CAST(o.sample_order_flag AS VARCHAR)) IN ('1','TRUE','T','Y','YES')"
        else:
            flag_check = "o.sample_order_flag = true"
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*)
            FROM main.production_sales ps
            JOIN {orders_src} o ON ps.order_id = o.order_id
            WHERE {flag_check}
        """)
        assert result == 0, f"Found {result} sample orders in production_sales"

    def test_no_internal_orders(self, db):
        """No internal orders should be in production_sales."""
        conn, db_type = db
        orders_src = get_orders_source(db_type)
        if db_type == 'snowflake':
            flag_check = "UPPER(CAST(o.internal_order_flag AS VARCHAR)) IN ('1','TRUE','T','Y','YES')"
        else:
            flag_check = "o.internal_order_flag = true"
        result = execute_scalar(conn, db_type, f"""
            SELECT count(*)
            FROM main.production_sales ps
            JOIN {orders_src} o ON ps.order_id = o.order_id
            WHERE {flag_check}
        """)
        assert result == 0, f"Found {result} internal orders in production_sales"

    def test_orders_reduced(self, db, expected_values):
        """Production sales should have fewer orders than source."""
        conn, db_type = db
        orders_src = get_orders_source(db_type)
        total_source = execute_scalar(conn, db_type, f"""
            SELECT count(*) FROM {orders_src}
        """)

        total_production = execute_scalar(conn, db_type, """
            SELECT count(*) FROM main.production_sales
        """)

        assert total_production < total_source, \
            f"Production sales ({total_production}) should be less than total orders ({total_source})"


#
# Phase 3: Revenue Validation
#

class TestRevenueValidation:
    """Verify revenue totals are correct after filtering."""

    def test_total_revenue(self, db, expected_values):
        """Total revenue should match expected production value."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT round(sum(grand_total), 2) FROM main.production_sales
        """)

        expected = expected_values['total_revenue']
        tolerance = 1.0  # Allow $1 tolerance for rounding

        assert abs(float(result) - expected) <= tolerance, \
            f"Total revenue {result} differs from expected {expected}"

    def test_revenue_reduced(self, db):
        """Production revenue should be less than total source revenue."""
        conn, db_type = db
        orders_src = get_orders_source(db_type)
        source_revenue = execute_scalar(conn, db_type, f"""
            SELECT sum(grand_total) FROM {orders_src}
        """)

        production_revenue = execute_scalar(conn, db_type, """
            SELECT sum(grand_total) FROM main.production_sales
        """)

        assert float(production_revenue) < float(source_revenue), \
            f"Production revenue ({production_revenue}) should be less than source ({source_revenue})"


#
# Phase 4: Data Quality Checks
#

class TestDataQuality:
    """Additional data quality validations."""

    def test_no_negative_totals(self, db):
        """Grand total should never be negative."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*) FROM main.production_sales WHERE grand_total < 0
        """)
        assert result == 0, f"Found {result} orders with negative grand_total"

    def test_valid_status_values(self, db):
        """Status values should be from expected set."""
        conn, db_type = db
        valid_statuses = ['COMPLETED', 'DELIVERED', 'SHIPPED', 'RETURNED',
                         'CANCELLED', 'PROCESSING', 'CONFIRMED', 'PENDING']

        result = execute_query(conn, db_type, """
            SELECT distinct status FROM main.production_sales
        """)

        actual_statuses = [row[0] for row in result if row[0] is not None]

        for status in actual_statuses:
            assert status in valid_statuses, f"Invalid status: {status}"

    def test_order_date_not_null(self, db):
        """Order date should not be null."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*) FROM main.production_sales WHERE order_date IS NULL
        """)
        assert result == 0, f"Found {result} orders with NULL order_date"

    def test_customer_id_not_null(self, db):
        """Customer ID should not be null for production orders."""
        conn, db_type = db
        result = execute_scalar(conn, db_type, """
            SELECT count(*) FROM main.production_sales WHERE customer_id IS NULL
        """)
        # Allow some NULL customer_ids (guest checkouts)
        assert result < 100, f"Found {result} orders with NULL customer_id (too many)"
