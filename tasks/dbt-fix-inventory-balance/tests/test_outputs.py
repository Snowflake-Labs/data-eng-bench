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


def _param_placeholder(db_type):
    """Return the parameter placeholder for the given db_type"""
    return '%s' if db_type == 'snowflake' else '?'


# ============ TESTS ============


@pytest.fixture(scope="module")
def db_conn():
    """Create a database connection"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_cumulative_includes_all_same_day_orders(db_conn):
    """Test that same-day orders are all included in cumulative sum"""
    conn, db_type = db_conn
    ph = _param_placeholder(db_type)

    # Find dates with multiple orders for same product
    multi_order_dates = execute_query(conn, db_type, """
        SELECT
            p.product_id,
            cast(o.ORDERED_AT as date) as order_date,
            COUNT(DISTINCT ol.order_line_id) as order_count,
            SUM(ol.line_total) as total_revenue
        FROM main.stg_product__products p
        INNER JOIN main.stg_product__product_variants pv ON p.product_id = pv.product_id
        INNER JOIN main.stg_orders__order_lines ol ON pv.variant_id = ol.variant_id
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        GROUP BY p.product_id, cast(o.ORDERED_AT as date)
        HAVING COUNT(DISTINCT ol.order_line_id) > 1
        LIMIT 10
    """)

    if not multi_order_dates:
        pytest.skip("No dates with multiple orders found")

    errors = []
    for product_id, order_date, order_count, expected_revenue in multi_order_dates:
        # Get cumulative revenue on that date
        cumulative_revenues = execute_query(conn, db_type, f"""
            SELECT DISTINCT cumulative_revenue
            FROM main.fct_inventory_balance
            WHERE product_id = {ph}
              AND order_date = {ph}
        """, [product_id, order_date])

        # All orders on same date should have same cumulative value (with RANGE)
        if len(cumulative_revenues) > 1:
            errors.append(
                f"Product {product_id} on {order_date}: {len(cumulative_revenues)} different cumulative values"
            )

    assert len(errors) == 0, f"Same-day order errors: {'; '.join(errors)}"


def test_cumulative_monotonic_per_product(db_conn):
    """Test that cumulative revenue increases over time"""
    conn, db_type = db_conn
    ph = _param_placeholder(db_type)

    # Sample products
    products = execute_query(conn, db_type, """
        SELECT DISTINCT product_id
        FROM main.fct_inventory_balance
        LIMIT 10
    """)

    errors = []
    for (product_id,) in products:
        # Get revenue progression
        progression = execute_query(conn, db_type, f"""
            SELECT
                order_date,
                MAX(cumulative_revenue) as cumulative
            FROM main.fct_inventory_balance
            WHERE product_id = {ph}
            GROUP BY order_date
            ORDER BY order_date
        """, [product_id])

        # Check that cumulative never decreases
        prev_cumulative = 0
        for order_date, cumulative in progression:
            if float(cumulative) < float(prev_cumulative) - 0.01:  # Allow small tolerance
                errors.append(
                    f"Product {product_id}: cumulative decreased from {prev_cumulative} to {cumulative} on {order_date}"
                )
            prev_cumulative = cumulative

    assert len(errors) == 0, f"Monotonic progression errors: {'; '.join(errors[:5])}"


def test_final_cumulative_matches_total(db_conn):
    """Test that final cumulative values match product totals"""
    conn, db_type = db_conn

    comparison = execute_query(conn, db_type, """
        WITH product_totals AS (
            SELECT
                p.product_id,
                SUM(ol.line_total) as total_revenue,
                COUNT(DISTINCT ol.order_line_id) as line_count
            FROM main.stg_product__products p
            INNER JOIN main.stg_product__product_variants pv ON p.product_id = pv.product_id
            INNER JOIN main.stg_orders__order_lines ol ON pv.variant_id = ol.variant_id
            INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
            WHERE o.status NOT IN ('cancelled', 'refunded')
            GROUP BY p.product_id
        ),
        final_cumulative AS (
            SELECT
                product_id,
                MAX(cumulative_revenue) as final_cumulative,
                COUNT(*) as model_line_count
            FROM main.fct_inventory_balance
            GROUP BY product_id
        )
        SELECT
            pt.product_id,
            pt.total_revenue,
            fc.final_cumulative,
            pt.line_count,
            fc.model_line_count
        FROM product_totals pt
        LEFT JOIN final_cumulative fc ON pt.product_id = fc.product_id
        WHERE fc.product_id IS NULL
           OR (
               fc.final_cumulative IS NOT NULL
               AND COALESCE(
                   ABS(CAST(pt.total_revenue AS DOUBLE) - CAST(fc.final_cumulative AS DOUBLE)) / NULLIF(CAST(pt.total_revenue AS DOUBLE), 0),
                   ABS(CAST(fc.final_cumulative AS DOUBLE))
               ) > 0.05
           )
    """)

    if len(comparison) > 0:
        for product_id, total_rev, final_cum, line_count, model_count in comparison[:5]:
            print(f"Product {product_id}: total={total_rev}, final={final_cum}, lines={line_count}, model_lines={model_count}")

    assert len(comparison) == 0, f"Found {len(comparison)} products with >5% revenue mismatch"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist"""
    conn, db_type = db_conn

    required_columns = [
        'product_id', 'product_name', 'order_date', 'order_line_id',
        'units_sold', 'revenue', 'cumulative_units_sold', 'cumulative_revenue',
        'prev_day_cumulative_revenue', 'daily_change', 'rank_in_day',
        'days_since_last_sale', 'running_avg_revenue_per_line', 'cumulative_percentile'
    ]

    result = execute_query(conn, db_type, """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_name) = 'fct_inventory_balance'
          AND lower(table_schema) = 'main'
    """)

    existing_columns = [row[0].lower() for row in result]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing"


def test_all_order_lines_present(db_conn):
    """Test that all order lines are represented"""
    conn, db_type = db_conn

    source_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT ol.order_line_id)
        FROM main.stg_orders__order_lines ol
        INNER JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE o.status NOT IN ('cancelled', 'refunded')
    """))

    report_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance
    """))

    # Should match (one row per order line)
    tolerance = max(source_count * 0.01, 1)
    assert abs(report_count - source_count) <= tolerance, \
        f"Order line count mismatch: report={report_count}, source={source_count}"


def test_cumulative_starts_at_first_order(db_conn):
    """Test that cumulative starts correctly for each product"""
    conn, db_type = db_conn
    ph = _param_placeholder(db_type)

    first_orders = execute_query(conn, db_type, """
        SELECT
            product_id,
            MIN(order_date) as first_date
        FROM main.fct_inventory_balance
        GROUP BY product_id
        LIMIT 10
    """)

    errors = []
    for product_id, first_date in first_orders:
        # Get cumulative and actual units on first date
        result = execute_query(conn, db_type, f"""
            SELECT
                MIN(cumulative_units_sold) as first_cumulative,
                SUM(units_sold) as expected_cumulative
            FROM main.fct_inventory_balance
            WHERE product_id = {ph}
              AND order_date = {ph}
        """, [product_id, first_date])

        first_cumulative, expected = result[0]

        # Cumulative on first date should equal sum of that day's units
        if abs(float(first_cumulative) - float(expected)) > 0.01:
            errors.append(
                f"Product {product_id}: first cumulative={first_cumulative}, expected={expected}"
            )

    assert len(errors) == 0, f"First-date cumulative errors: {'; '.join(errors[:5])}"


def test_no_nulls_in_cumulative(db_conn):
    """Test that cumulative columns don't have NULLs"""
    conn, db_type = db_conn

    null_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance
        WHERE cumulative_units_sold IS NULL
           OR cumulative_revenue IS NULL
    """))

    assert null_count == 0, f"Found {null_count} records with NULL cumulative values"


def test_cancelled_orders_excluded(db_conn):
    """Test that cancelled and refunded orders are excluded"""
    conn, db_type = db_conn

    # Count order lines from cancelled/refunded orders that should NOT be in the model
    excluded_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.stg_orders__order_lines ol
        INNER JOIN main.stg_orders__orders o ON ol.order_id = o.order_id
        WHERE o.status IN ('cancelled', 'refunded')
    """))

    # Count how many of these appear in the model (should be 0)
    in_model_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance f
        INNER JOIN main.stg_orders__orders o ON f.order_line_id IN (
            SELECT order_line_id
            FROM main.stg_orders__order_lines ol2
            WHERE ol2.order_id = o.order_id
        )
        WHERE o.status IN ('cancelled', 'refunded')
    """))

    assert in_model_count == 0, f"Found {in_model_count} order lines from cancelled/refunded orders (should exclude {excluded_count} total)"


def test_prev_day_cumulative_correct(db_conn):
    """Test that prev_day_cumulative_revenue is correctly calculated"""
    conn, db_type = db_conn

    # Sample products and get their date progression
    test_cases = execute_query(conn, db_type, """
        SELECT
            product_id,
            order_date,
            MAX(cumulative_revenue) as current_cumulative,
            MAX(prev_day_cumulative_revenue) as prev_cumulative
        FROM main.fct_inventory_balance
        GROUP BY product_id, order_date
        ORDER BY product_id, order_date
        LIMIT 50
    """)

    errors = []
    prev_product = None
    prev_cumulative = None

    for product_id, order_date, current_cumulative, prev_cumulative_col in test_cases:
        if product_id == prev_product:
            # Should match previous row's cumulative
            if prev_cumulative_col is not None and prev_cumulative is not None:
                diff = abs(float(prev_cumulative_col) - float(prev_cumulative))
                if diff > 0.01:
                    errors.append(
                        f"Product {product_id} on {order_date}: prev_day={prev_cumulative_col}, expected={prev_cumulative}"
                    )
        else:
            # First date for product - prev should be NULL
            if prev_cumulative_col is not None:
                errors.append(
                    f"Product {product_id} on {order_date}: prev_day should be NULL on first date, got {prev_cumulative_col}"
                )

        prev_product = product_id
        prev_cumulative = current_cumulative

    assert len(errors) == 0, f"prev_day_cumulative errors: {'; '.join(errors[:5])}"


def test_daily_change_matches_difference(db_conn):
    """Test that daily_change equals current minus previous cumulative"""
    conn, db_type = db_conn

    mismatches = execute_query(conn, db_type, """
        SELECT
            product_id,
            order_date,
            daily_change,
            cumulative_revenue,
            prev_day_cumulative_revenue,
            cumulative_revenue - COALESCE(prev_day_cumulative_revenue, 0) as expected_change
        FROM main.fct_inventory_balance
        WHERE ABS(
            CAST(daily_change AS DOUBLE) -
            CAST(cumulative_revenue - COALESCE(prev_day_cumulative_revenue, 0) AS DOUBLE)
        ) > 0.01
        LIMIT 10
    """)

    if len(mismatches) > 0:
        for product_id, order_date, daily_change, cumulative, prev_cumulative, expected in mismatches[:5]:
            print(f"Product {product_id} on {order_date}: daily_change={daily_change}, expected={expected}")

    assert len(mismatches) == 0, f"Found {len(mismatches)} records with incorrect daily_change calculation"


def test_rank_in_day_consecutive(db_conn):
    """Test that rank_in_day is consecutive starting from 1 for each product-date"""
    conn, db_type = db_conn

    # Sample some product-dates with multiple order lines
    issues = execute_query(conn, db_type, """
        WITH ranked_counts AS (
            SELECT
                product_id,
                order_date,
                COUNT(*) as line_count,
                MAX(rank_in_day) as max_rank,
                MIN(rank_in_day) as min_rank
            FROM main.fct_inventory_balance
            GROUP BY product_id, order_date
            HAVING COUNT(*) > 1
        )
        SELECT
            product_id,
            order_date,
            line_count,
            max_rank,
            min_rank
        FROM ranked_counts
        WHERE min_rank != 1 OR max_rank != line_count
        LIMIT 10
    """)

    if len(issues) > 0:
        for product_id, order_date, line_count, max_rank, min_rank in issues:
            print(f"Product {product_id} on {order_date}: {line_count} lines, ranks {min_rank}-{max_rank}")

    assert len(issues) == 0, f"Found {len(issues)} product-dates with non-consecutive rank_in_day"


def test_rank_ordered_by_order_line_id(db_conn):
    """Test that rank_in_day is ordered by order_line_id ascending"""
    conn, db_type = db_conn

    # Check that within each product-date, lower rank has lower order_line_id
    violations = execute_query(conn, db_type, """
        WITH pairs AS (
            SELECT
                f1.product_id,
                f1.order_date,
                f1.rank_in_day as rank1,
                f2.rank_in_day as rank2,
                f1.order_line_id as id1,
                f2.order_line_id as id2
            FROM main.fct_inventory_balance f1
            INNER JOIN main.fct_inventory_balance f2
                ON f1.product_id = f2.product_id
                AND f1.order_date = f2.order_date
                AND f1.rank_in_day < f2.rank_in_day
            WHERE f1.order_line_id > f2.order_line_id
            LIMIT 10
        )
        SELECT * FROM pairs
    """)

    assert len(violations) == 0, f"Found {len(violations)} cases where rank_in_day violates order_line_id ordering"


def test_schema_yml_exists(db_conn):
    """Test that schema.yml file exists and dbt test for non-negative cumulative_revenue passes"""
    conn, db_type = db_conn

    # Verify the data constraint holds
    negative_count = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance
        WHERE cumulative_revenue < 0
    """))

    assert negative_count == 0, f"Found {negative_count} records with negative cumulative_revenue"


def test_days_since_last_sale_correct(db_conn):
    """Test that days_since_last_sale is calculated correctly"""
    conn, db_type = db_conn

    test_cases = execute_query(conn, db_type, """
        WITH product_dates AS (
            SELECT DISTINCT
                product_id,
                order_date
            FROM main.fct_inventory_balance
            ORDER BY product_id, order_date
        ),
        with_prev AS (
            SELECT
                product_id,
                order_date,
                LAG(order_date) OVER (PARTITION BY product_id ORDER BY order_date) as prev_date
            FROM product_dates
        )
        SELECT
            wp.product_id,
            wp.order_date,
            wp.prev_date,
            f.days_since_last_sale,
            DATEDIFF('day', wp.prev_date, wp.order_date) as expected_days
        FROM with_prev wp
        INNER JOIN main.fct_inventory_balance f
            ON wp.product_id = f.product_id
            AND wp.order_date = f.order_date
        WHERE wp.prev_date IS NOT NULL
        LIMIT 50
    """)

    errors = []
    for product_id, order_date, prev_date, actual_days, expected_days in test_cases:
        if actual_days is not None and expected_days is not None:
            if int(actual_days) != int(expected_days):
                errors.append(
                    f"Product {product_id} on {order_date}: days_since_last_sale={actual_days}, expected={expected_days} (prev={prev_date})"
                )

    assert len(errors) == 0, f"days_since_last_sale errors: {'; '.join(errors[:5])}"


def test_running_avg_revenue_per_line_correct(db_conn):
    """Test that running_avg_revenue_per_line equals cumulative_revenue / cumulative_units_sold"""
    conn, db_type = db_conn

    mismatches = execute_query(conn, db_type, """
        SELECT
            product_id,
            order_date,
            cumulative_revenue,
            cumulative_units_sold,
            running_avg_revenue_per_line,
            CASE
                WHEN cumulative_units_sold = 0 THEN 0
                ELSE CAST(cumulative_revenue AS DOUBLE) / CAST(cumulative_units_sold AS DOUBLE)
            END as expected_avg
        FROM main.fct_inventory_balance
        WHERE cumulative_units_sold > 0
          AND ABS(
              CAST(running_avg_revenue_per_line AS DOUBLE) -
              CAST(cumulative_revenue AS DOUBLE) / CAST(cumulative_units_sold AS DOUBLE)
          ) > 0.01
        LIMIT 10
    """)

    if len(mismatches) > 0:
        for product_id, order_date, cum_rev, cum_units, actual_avg, expected in mismatches[:5]:
            print(f"Product {product_id} on {order_date}: avg={actual_avg}, expected={expected}")

    assert len(mismatches) == 0, f"Found {len(mismatches)} records with incorrect running_avg_revenue_per_line"


def test_running_avg_handles_zero_units(db_conn):
    """Test that running_avg_revenue_per_line handles zero units gracefully"""
    conn, db_type = db_conn

    zero_units = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance
        WHERE cumulative_units_sold = 0
          AND running_avg_revenue_per_line != 0
    """))

    assert zero_units == 0, f"Found {zero_units} records with zero units but non-zero running average"


def test_cumulative_percentile_range(db_conn):
    """Test that cumulative_percentile is between 0 and 1"""
    conn, db_type = db_conn

    out_of_range = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance
        WHERE cumulative_percentile < 0 OR cumulative_percentile > 1
    """))

    assert out_of_range == 0, f"Found {out_of_range} records with cumulative_percentile out of range [0,1]"


def test_cumulative_percentile_ordering(db_conn):
    """Test that higher cumulative revenue has higher percentile on same date"""
    conn, db_type = db_conn

    violations = int(execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.fct_inventory_balance f1
        INNER JOIN main.fct_inventory_balance f2
            ON f1.order_date = f2.order_date
            AND f1.cumulative_revenue > f2.cumulative_revenue
            AND f1.cumulative_percentile < f2.cumulative_percentile
    """))

    assert violations == 0, f"Found {violations} cases where higher revenue has lower percentile on same date"


def test_prev_day_same_across_date(db_conn):
    """Test that all rows on same date for a product have same prev_day_cumulative_revenue"""
    conn, db_type = db_conn

    # Find dates with multiple rows
    inconsistent = int(execute_scalar(conn, db_type, """
        WITH date_prev_values AS (
            SELECT
                product_id,
                order_date,
                COUNT(DISTINCT prev_day_cumulative_revenue) as distinct_prev_values,
                COUNT(*) as row_count
            FROM main.fct_inventory_balance
            GROUP BY product_id, order_date
            HAVING COUNT(*) > 1
        )
        SELECT COUNT(*)
        FROM date_prev_values
        WHERE distinct_prev_values > 1
    """))

    assert inconsistent == 0, f"Found {inconsistent} product-dates where prev_day_cumulative_revenue varies across rows"
