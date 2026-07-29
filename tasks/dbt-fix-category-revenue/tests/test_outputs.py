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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def get_param_placeholder(db_type):
    """Return the correct SQL parameter placeholder for the backend"""
    if db_type == 'snowflake':
        return '%s'
    return '?'


# ============ TESTS ============


@pytest.fixture(scope="module")
def db_conn():
    """Create a connection to the database"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_total_revenue_matches_order_lines(db_conn):
    """Test that total revenue in report matches actual order line totals"""
    conn, db_type = db_conn

    # Get total from the report
    report_total = float(execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(revenue), 0) as total
        FROM main.rpt_category_performance
    """) or 0)

    # Get actual total from order lines
    actual_total = float(execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(ol.line_total), 0) as total
        FROM main.stg_orders__order_lines ol
        JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
    """) or 0)

    # Allow 0.01% tolerance for rounding
    tolerance = actual_total * 0.0001
    assert abs(report_total - actual_total) <= tolerance, \
        f"Revenue mismatch: report={report_total}, actual={actual_total}, diff={report_total - actual_total}"


def test_no_double_counting_for_multi_variant_products(db_conn):
    """Test that products with multiple variants don't inflate revenue"""
    conn, db_type = db_conn
    ph = get_param_placeholder(db_type)

    # Find a product with multiple variants that has been sold
    multi_variant_product = execute_query(conn, db_type, """
        SELECT pv.product_id, p.product_type, COUNT(DISTINCT pv.variant_id) as variant_count
        FROM main.stg_product__product_variants pv
        JOIN main.stg_product__products p ON pv.product_id = p.product_id
        WHERE EXISTS (
            SELECT 1 FROM main.stg_orders__order_lines ol
            WHERE ol.variant_id = pv.variant_id
        )
        GROUP BY pv.product_id, p.product_type
        HAVING COUNT(DISTINCT pv.variant_id) > 1
        LIMIT 1
    """)

    if not multi_variant_product:
        pytest.skip("No multi-variant products with sales found")

    product_id = multi_variant_product[0][0]
    product_type = multi_variant_product[0][1]
    variant_count = int(multi_variant_product[0][2])

    # Get revenue for this category from report
    report_revenue = float(execute_scalar(conn, db_type, f"""
        SELECT COALESCE(SUM(revenue), 0) as total
        FROM main.rpt_category_performance
        WHERE category = {ph}
    """, [product_type]) or 0)

    # Get actual revenue from order lines for this category
    actual_revenue = float(execute_scalar(conn, db_type, f"""
        SELECT COALESCE(SUM(ol.line_total), 0) as total
        FROM main.stg_orders__order_lines ol
        JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
        JOIN main.stg_product__products p ON pv.product_id = p.product_id
        WHERE p.product_type = {ph}
    """, [product_type]) or 0)

    tolerance = actual_revenue * 0.0001
    assert abs(report_revenue - actual_revenue) <= tolerance, \
        f"Multi-variant product revenue inflated: product_id={product_id}, variants={variant_count}"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist in output"""
    conn, db_type = db_conn

    required_columns = [
        'category', 'sales_month', 'unique_products', 'orders',
        'units_sold', 'revenue', 'avg_unit_price', 'gross_profit'
    ]

    result = execute_query(conn, db_type, """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_name) = 'rpt_category_performance'
          AND lower(table_schema) = 'main'
    """)

    existing_columns = [row[0].lower() for row in result]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing"


def test_no_null_revenue_for_categories_with_sales(db_conn):
    """Test that categories with actual sales don't have NULL revenue"""
    conn, db_type = db_conn

    null_revenue_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT rpt.category)
        FROM main.rpt_category_performance rpt
        WHERE rpt.revenue IS NULL
          AND EXISTS (
              SELECT 1
              FROM main.stg_orders__order_lines ol
              JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
              JOIN main.stg_product__products p ON pv.product_id = p.product_id
              WHERE p.product_type = rpt.category
          )
    """) or 0)

    assert null_revenue_count == 0, f"Found {null_revenue_count} categories with sales but NULL revenue"


def test_revenue_by_category_accuracy(db_conn):
    """Test revenue accuracy for each category individually"""
    conn, db_type = db_conn
    ph = get_param_placeholder(db_type)

    # Get all categories
    categories = execute_query(conn, db_type, """
        SELECT DISTINCT category
        FROM main.rpt_category_performance
        WHERE category IS NOT NULL
        LIMIT 10
    """)

    errors = []
    for (category,) in categories:
        # Report revenue
        report_rev = float(execute_scalar(conn, db_type, f"""
            SELECT COALESCE(SUM(revenue), 0)
            FROM main.rpt_category_performance
            WHERE category = {ph}
        """, [category]) or 0)

        # Actual revenue
        actual_rev = float(execute_scalar(conn, db_type, f"""
            SELECT COALESCE(SUM(ol.line_total), 0)
            FROM main.stg_orders__order_lines ol
            JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
            JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
            JOIN main.stg_product__products p ON pv.product_id = p.product_id
            WHERE p.product_type = {ph}
        """, [category]) or 0)

        tolerance = max(actual_rev * 0.0001, 0.01)
        if abs(report_rev - actual_rev) > tolerance:
            errors.append(f"{category}: report={report_rev}, actual={actual_rev}")

    assert len(errors) == 0, f"Revenue mismatch for categories: {'; '.join(errors)}"


def test_order_count_accuracy(db_conn):
    """Test that order counts are correct"""
    conn, db_type = db_conn

    # Total orders in report
    report_orders = int(execute_scalar(conn, db_type, """
        SELECT SUM(orders) as total
        FROM main.rpt_category_performance
    """) or 0)

    # Actual unique orders (note: an order can have multiple categories)
    actual_orders = int(execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT o.order_id) as total
        FROM main.stg_orders__orders o
        JOIN main.stg_orders__order_lines ol ON o.order_id = ol.order_id
    """) or 0)

    # Report sum can be >= actual because one order can span multiple categories
    assert report_orders >= actual_orders * 0.9, \
        f"Order count too low: report={report_orders}, actual={actual_orders}"


def test_units_sold_accuracy(db_conn):
    """Test that total units sold matches order lines"""
    conn, db_type = db_conn

    # Total from report
    report_units = float(execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(units_sold), 0) as total
        FROM main.rpt_category_performance
    """) or 0)

    # Actual total
    actual_units = float(execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(quantity_ordered), 0) as total
        FROM main.stg_orders__order_lines ol
        JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
    """) or 0)

    # Buggy version will have MORE units (fan-out causes duplication)
    # Fixed version should match exactly
    tolerance = actual_units * 0.0001
    assert abs(report_units - actual_units) <= tolerance, \
        f"Units sold mismatch: report={report_units}, actual={actual_units}"


def test_gross_profit_not_null_when_cost_available(db_conn):
    """Test that gross profit is calculated when cost data exists"""
    conn, db_type = db_conn

    # Check if we have any variants with cost_price
    has_costs = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.stg_product__product_variants
        WHERE cost_price IS NOT NULL AND cost_price > 0
    """) or 0)

    if has_costs == 0:
        pytest.skip("No cost price data available")

    # Check that report has gross_profit calculated
    null_profit_with_costs = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_category_performance cp
        WHERE cp.revenue > 0
          AND cp.gross_profit IS NULL
          AND EXISTS (
              SELECT 1
              FROM main.stg_orders__order_lines ol
              JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
              JOIN main.stg_product__products p ON pv.product_id = p.product_id
              WHERE p.product_type = cp.category
                AND pv.cost_price IS NOT NULL
          )
    """) or 0)

    assert null_profit_with_costs == 0, \
        f"Found {null_profit_with_costs} categories with revenue and cost data but NULL gross_profit"


def test_no_negative_revenue(db_conn):
    """Test that revenue values are non-negative"""
    conn, db_type = db_conn

    negative_revenue_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.rpt_category_performance
        WHERE revenue < 0
    """) or 0)

    assert negative_revenue_count == 0, \
        f"Found {negative_revenue_count} records with negative revenue"


def test_product_count_accuracy(db_conn):
    """Test that unique product counts match actual sold products per category per month"""
    conn, db_type = db_conn
    ph = get_param_placeholder(db_type)

    # Get a sample row to validate
    sample_rows = execute_query(conn, db_type, """
        SELECT category, sales_month, unique_products
        FROM main.rpt_category_performance
        WHERE unique_products > 0
        ORDER BY category, sales_month
        LIMIT 1
    """)

    if not sample_rows:
        pytest.skip("No data in report")

    sample_row = sample_rows[0]
    category = sample_row[0]
    sales_month = sample_row[1]
    report_count = int(sample_row[2])

    # Get actual count for this specific category-month
    actual_count = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT p.product_id)
        FROM main.stg_product__products p
        JOIN main.stg_product__product_variants pv ON p.product_id = pv.product_id
        JOIN main.stg_orders__order_lines ol ON pv.variant_id = ol.variant_id
        JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE p.product_type = {ph}
          AND date_trunc('month', cast(o.ordered_at as timestamp)) = {ph}
    """, [category, sales_month]) or 0)

    assert report_count == actual_count, \
        f"Product count mismatch for {category} {sales_month}: report={report_count}, actual={actual_count}"
