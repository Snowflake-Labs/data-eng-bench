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


# ============ END DUAL-BACKEND INFRASTRUCTURE ============

# SQL fragment: valid order statuses (exclude cancelled, returned, failed)
VALID_ORDER_FILTER = "status NOT IN ('CANCELLED', 'RETURNED', 'FAILED')"


@pytest.fixture(scope="module")
def db_conn():
    """Create a database connection"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_product_revenue_matches_order_lines(db_conn):
    """Test that product revenue matches actual order line totals for valid orders only.
    Revenue should exclude cancelled, returned, and failed orders.
    Tolerance is 0.01 (exact to 2 decimal places).
    """
    conn, db_type = db_conn

    # Get total from report
    report_total = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(product_revenue), 0) as total
        FROM main.fct_product_metrics
    """)

    # Get actual total from order lines for valid orders only
    actual_total = execute_scalar(conn, db_type, f"""
        SELECT COALESCE(SUM(ol.line_total), 0) as total
        FROM main.stg_orders__order_lines ol
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE o.{VALID_ORDER_FILTER}
    """)

    assert abs(float(report_total) - float(actual_total)) <= 0.01, \
        f"Revenue mismatch: report={report_total}, actual={actual_total} (tolerance=0.01)"


def test_data_quality_check_2(db_conn):
    """Test data accuracy for a specific product with multiple variants.
    Validates that per-product revenue matches the sum of valid order line totals.
    """
    conn, db_type = db_conn

    # Find a product with multiple variants and valid orders
    product_check = execute_query(conn, db_type, f"""
        SELECT
            pv.product_id,
            COUNT(DISTINCT pv.variant_id) as variant_count,
            COUNT(DISTINCT ol.order_line_id) as order_lines
        FROM main.stg_product__product_variants pv
        INNER JOIN main.stg_orders__order_lines ol ON pv.variant_id = ol.variant_id
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE o.{VALID_ORDER_FILTER}
        GROUP BY pv.product_id
        HAVING COUNT(DISTINCT pv.variant_id) > 1
        LIMIT 1
    """)

    if not product_check:
        pytest.skip("No products with multiple variants and valid orders found")

    product_id = product_check[0][0]

    # Get revenue from report for this product
    if db_type == 'snowflake':
        report_revenue = execute_scalar(conn, db_type,
            "SELECT product_revenue FROM main.fct_product_metrics WHERE product_id = %s",
            [product_id])
    else:
        report_revenue = execute_scalar(conn, db_type,
            "SELECT product_revenue FROM main.fct_product_metrics WHERE product_id = ?",
            [product_id])

    # Get actual revenue from valid order lines only
    if db_type == 'snowflake':
        actual_revenue = execute_scalar(conn, db_type, f"""
            SELECT SUM(ol.line_total)
            FROM main.stg_orders__order_lines ol
            INNER JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
            INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
            WHERE pv.product_id = %s
              AND o.{VALID_ORDER_FILTER}
        """, [product_id])
    else:
        actual_revenue = execute_scalar(conn, db_type, f"""
            SELECT SUM(ol.line_total)
            FROM main.stg_orders__order_lines ol
            INNER JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
            INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
            WHERE pv.product_id = ?
              AND o.{VALID_ORDER_FILTER}
        """, [product_id])

    assert abs(float(report_revenue) - float(actual_revenue)) <= 0.01, \
        f"Data validation failed for product {product_id}: report={report_revenue}, actual={actual_revenue}"


def test_units_sold_accuracy(db_conn):
    """Test that units sold matches order lines for valid orders only.
    Tolerance is 0.01 (exact match expected for integer quantities).
    """
    conn, db_type = db_conn

    report_units = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(units_sold), 0)
        FROM main.fct_product_metrics
    """)

    actual_units = execute_scalar(conn, db_type, f"""
        SELECT COALESCE(SUM(ol.quantity_ordered), 0)
        FROM main.stg_orders__order_lines ol
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE o.{VALID_ORDER_FILTER}
    """)

    assert abs(float(report_units) - float(actual_units)) <= 0.01, \
        f"Units sold mismatch: report={report_units}, actual={actual_units}"


def test_order_count_accuracy(db_conn):
    """Test that order counts are reasonable relative to valid orders only."""
    conn, db_type = db_conn

    # Total orders in report (can be higher than actual if products in multiple orders)
    report_orders = execute_scalar(conn, db_type, """
        SELECT SUM(total_orders)
        FROM main.fct_product_metrics
    """)

    # Actual unique valid orders
    actual_orders = execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT order_id)
        FROM main.stg_orders__orders
        WHERE {VALID_ORDER_FILTER}
    """)

    # Report sum should be >= actual (products can be in multiple orders)
    assert int(report_orders) >= int(actual_orders) * 0.5, \
        f"Order count too low: report_sum={report_orders}, actual={actual_orders}"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist"""
    conn, db_type = db_conn

    required_columns = [
        'product_id', 'product_name', 'category', 'total_orders',
        'units_sold', 'product_revenue', 'avg_unit_price', 'total_variants'
    ]

    result = execute_query(conn, db_type, """
        SELECT lower(column_name)
        FROM information_schema.columns
        WHERE lower(table_name) = 'fct_product_metrics'
          AND lower(table_schema) = 'main'
    """)

    existing_columns = [row[0] for row in result]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing"


def test_variant_counts_match(db_conn):
    """Test that variant counts are accurate"""
    conn, db_type = db_conn

    # Check a product with known variants
    product_check = execute_query(conn, db_type, """
        SELECT
            pv.product_id,
            COUNT(DISTINCT pv.variant_id) as actual_variants
        FROM main.stg_product__product_variants pv
        GROUP BY pv.product_id
        HAVING COUNT(DISTINCT pv.variant_id) > 1
        LIMIT 1
    """)

    if not product_check:
        pytest.skip("No products with multiple variants found")

    product_id = product_check[0][0]
    actual_variants = int(product_check[0][1])

    if db_type == 'snowflake':
        report_variants = execute_scalar(conn, db_type,
            "SELECT total_variants FROM main.fct_product_metrics WHERE product_id = %s",
            [product_id])
    else:
        report_variants = execute_scalar(conn, db_type,
            "SELECT total_variants FROM main.fct_product_metrics WHERE product_id = ?",
            [product_id])

    assert int(report_variants) == actual_variants, \
        f"Variant count mismatch for product {product_id}: report={report_variants}, actual={actual_variants}"


def test_no_negative_values(db_conn):
    """Test that metrics don't have negative values"""
    conn, db_type = db_conn

    negative_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_product_metrics
        WHERE product_revenue < 0
           OR units_sold < 0
           OR total_orders < 0
           OR total_variants < 0
    """)

    assert int(negative_count) == 0, f"Found {negative_count} records with negative values"


def test_all_products_present(db_conn):
    """Test that all products are in the metrics"""
    conn, db_type = db_conn

    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT product_id)
        FROM main.stg_product__products
    """)

    report_count = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT product_id)
        FROM main.fct_product_metrics
    """)

    assert int(report_count) == int(source_count), \
        f"Product count mismatch: report={report_count}, source={source_count}"


def test_no_cancelled_orders_included(db_conn):
    """Verify that revenue does not include cancelled, returned, or failed orders.

    Cross-checks the report's total revenue against an independent calculation
    from source tables that explicitly excludes invalid order statuses. If the
    agent included all orders without filtering, the report total will be higher
    than the valid-only total, causing this test to fail.
    """
    conn, db_type = db_conn

    # Revenue from the report
    report_revenue = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(product_revenue), 0)
        FROM main.fct_product_metrics
    """)

    # Revenue from ALL order lines (no status filter)
    all_revenue = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(line_total), 0)
        FROM main.stg_orders__order_lines
    """)

    # Revenue from VALID order lines only
    valid_revenue = execute_scalar(conn, db_type, f"""
        SELECT COALESCE(SUM(ol.line_total), 0)
        FROM main.stg_orders__order_lines ol
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE o.{VALID_ORDER_FILTER}
    """)

    report_val = float(report_revenue)
    all_val = float(all_revenue)
    valid_val = float(valid_revenue)

    # The report should match valid revenue, NOT all revenue
    # If there are any invalid orders, all_val > valid_val, so matching all_val means the agent didn't filter
    assert abs(report_val - valid_val) <= 0.01, \
        (f"Report revenue ({report_val}) does not match valid-orders-only revenue ({valid_val}). "
         f"Total unfiltered revenue is {all_val}. "
         f"Cancelled/returned/failed orders must be excluded.")


def test_product_count_matches_source(db_conn):
    """Verify total product count in report matches the products dimension table.

    The model starts from the products table and LEFT JOINs to sales data,
    so total row count should equal the number of distinct products in the
    products table (including those with zero sales).
    """
    conn, db_type = db_conn

    # Total products in the source dimension table
    source_product_count = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT product_id)
        FROM main.stg_product__products
    """)

    # Total products in the report
    report_product_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_product_metrics
    """)

    assert int(report_product_count) == int(source_product_count), \
        (f"Product count in report ({report_product_count}) "
         f"does not match source products table ({source_product_count})")


def test_avg_unit_price_formula(db_conn):
    """Verify that avg_unit_price equals product_revenue / units_sold for products
    with sales.

    The average unit price should be computed as total revenue divided by total
    units sold, not as a simple average of the unit_price column. This test
    checks all products with non-zero units_sold to ensure the formula is correct
    to within 0.01.
    """
    conn, db_type = db_conn

    # Find products where avg_unit_price != product_revenue / units_sold
    mismatches = execute_query(conn, db_type, """
        SELECT
            product_id,
            product_revenue,
            units_sold,
            avg_unit_price,
            CASE WHEN units_sold > 0 THEN product_revenue / units_sold ELSE 0 END as expected_avg
        FROM main.fct_product_metrics
        WHERE units_sold > 0
          AND ABS(avg_unit_price - (product_revenue / units_sold)) > 0.01
    """)

    assert len(mismatches) == 0, \
        (f"Found {len(mismatches)} products where avg_unit_price != product_revenue / units_sold. "
         f"First mismatch: product_id={mismatches[0][0]}, revenue={mismatches[0][1]}, "
         f"units={mismatches[0][2]}, avg_price={mismatches[0][3]}, expected={mismatches[0][4]}")
