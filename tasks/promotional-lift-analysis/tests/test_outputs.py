"""
Tests for Promotional Lift Analysis task.
"""
import os
import subprocess
import csv
import pytest


RESULT_PATH = '/app/promo_lift_results.csv'
DB_PATH = '/app/database/retail.duckdb'


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
            schema='promo_analytics',
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        if not os.path.exists(DB_PATH):
            pytest.skip(f"Database not found at {DB_PATH}")
        conn = duckdb.connect(DB_PATH, read_only=True)
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


def get_date_sub_expr(db_type, date_col, days):
    """Get date subtraction expression that works for both DuckDB and Snowflake"""
    if db_type == 'snowflake':
        return f"DATEADD(day, -{days}, {date_col})"
    else:
        return f"{date_col} - INTERVAL {days} DAY"


def safe_float(val, default=0.0):
    """Safely convert value to float, handling empty strings and None."""
    if val is None or val == '' or str(val).strip() == '':
        return default
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def test_dbt_model_exists():
    """Test that the dbt model promo_lift_analysis exists in promo_analytics schema."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE LOWER(table_schema) = 'promo_analytics'
            AND LOWER(table_name) = 'promo_lift_analysis'
        """)
        assert result > 0, \
            "dbt model promo_lift_analysis not found in promo_analytics schema. Did you run 'dbt run'?"
    finally:
        conn.close()


def test_result_file_exists():
    """Test that the result.csv file was created."""
    assert os.path.exists(RESULT_PATH), "promo_lift_results.csv file was not created"


def test_has_required_columns():
    """Test that output has required columns."""
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        columns = set(col.lower() for col in reader.fieldnames)

    required = {
        'promotion_id', 'promotion_name', 'promotion_duration_days',
        'targeted_products_count', 'redemption_count', 'total_discount_given',
        'avg_discount_per_order', 'baseline_daily_avg', 'redeemed_order_revenue',
        'estimated_lift', 'roi_pct'
    }
    missing = required - columns
    assert not missing, f"Missing required columns: {missing}"


def test_all_promotions_have_targeted_products():
    """Test that all output promotions have at least 1 targeted product (targeted_products_count > 0)."""
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            targeted_count = int(row.get('targeted_products_count', row.get('TARGETED_PRODUCTS_COUNT', 0)))
            assert targeted_count > 0, \
                f"Promotion {promo_id} has targeted_products_count={targeted_count}, must be > 0"


def test_only_promotions_with_redemptions():
    """Test that only promotions with at least 1 redemption (excluding test orders) are included."""
    conn, db_type = get_db_connection()

    # Get promotions with redemptions from database (excluding test/sample/internal orders)
    db_promos_with_redemptions = execute_query(conn, db_type, """
        SELECT DISTINCT pr.PROMOTION_ID
        FROM MARKETING.PROMOTION_REDEMPTIONS pr
        JOIN ORDERS.ORDERS o ON pr.ORDER_ID = o.ORDER_ID
        WHERE (o.TEST_ORDER_FLAG IS NULL OR UPPER(CAST(o.TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(o.SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(o.INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
    """)
    db_promo_ids = set(row[0] for row in db_promos_with_redemptions)
    conn.close()

    # Get promotions from result file
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        result_promo_ids = set()
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            result_promo_ids.add(promo_id)

    # All result promos should be in the set of promos with redemptions
    invalid_promos = result_promo_ids - db_promo_ids
    assert not invalid_promos, f"Found promotions without redemptions: {list(invalid_promos)[:3]}"


def test_redemption_count_accuracy():
    """Test that redemption counts match database (excluding test/sample/internal orders)."""
    conn, db_type = get_db_connection()

    # Get expected redemption counts (excluding test/sample/internal orders)
    expected = execute_query(conn, db_type, """
        SELECT pr.PROMOTION_ID, COUNT(*) as cnt
        FROM MARKETING.PROMOTION_REDEMPTIONS pr
        JOIN ORDERS.ORDERS o ON pr.ORDER_ID = o.ORDER_ID
        WHERE (o.TEST_ORDER_FLAG IS NULL OR UPPER(CAST(o.TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(o.SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(o.INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
        GROUP BY pr.PROMOTION_ID
    """)
    expected_counts = {row[0]: row[1] for row in expected}
    conn.close()

    # Check result file
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_count = int(row.get('redemption_count', row.get('REDEMPTION_COUNT', 0)))
            expected_count = expected_counts.get(promo_id, 0)
            assert actual_count == expected_count, \
                f"Redemption count mismatch for {promo_id}: expected {expected_count}, got {actual_count}"


def test_total_discount_accuracy():
    """Test that total discount given matches database (excluding test/sample/internal orders)."""
    conn, db_type = get_db_connection()

    expected = execute_query(conn, db_type, """
        SELECT pr.PROMOTION_ID, SUM(pr.DISCOUNT_AMOUNT) as total
        FROM MARKETING.PROMOTION_REDEMPTIONS pr
        JOIN ORDERS.ORDERS o ON pr.ORDER_ID = o.ORDER_ID
        WHERE (o.TEST_ORDER_FLAG IS NULL OR UPPER(CAST(o.TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(o.SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(o.INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
        GROUP BY pr.PROMOTION_ID
    """)
    expected_totals = {row[0]: float(row[1]) for row in expected}
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_total = safe_float(row.get('total_discount_given', row.get('TOTAL_DISCOUNT_GIVEN', '')), 0.0)
            expected_total = expected_totals.get(promo_id, 0.0)
            assert abs(actual_total - expected_total) < 0.02, \
                f"Total discount mismatch for {promo_id}: expected {expected_total:.2f}, got {actual_total:.2f}"


def test_promotion_duration_calculation():
    """Test that promotion duration is calculated correctly."""
    conn, db_type = get_db_connection()

    expected = execute_query(conn, db_type, """
        SELECT
            PROMOTION_ID,
            DATEDIFF('day', CAST(START_DATE AS DATE), CAST(END_DATE AS DATE)) + 1 as duration
        FROM MARKETING.PROMOTIONS
    """)
    expected_durations = {row[0]: int(row[1]) for row in expected}
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_duration = int(row.get('promotion_duration_days', row.get('PROMOTION_DURATION_DAYS', 0)))
            expected_duration = expected_durations.get(promo_id, 0)
            assert actual_duration == expected_duration, \
                f"Duration mismatch for {promo_id}: expected {expected_duration}, got {actual_duration}"


def test_targeted_products_count():
    """Test that targeted products count considers both product and brand targeting."""
    conn, db_type = get_db_connection()

    # Calculate expected targeted product counts
    expected = execute_query(conn, db_type, """
        WITH promotion_products AS (
            SELECT DISTINCT
                pp.PROMOTION_ID,
                COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) as PRODUCT_ID
            FROM MARKETING.PROMOTION_PRODUCTS pp
            LEFT JOIN PRODUCT.PRODUCTS p ON (
                (pp.PRODUCT_ID IS NOT NULL AND pp.PRODUCT_ID = p.PRODUCT_ID)
                OR (pp.BRAND_ID IS NOT NULL AND pp.BRAND_ID = p.BRAND_ID)
            )
            WHERE COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) IS NOT NULL
        )
        SELECT PROMOTION_ID, COUNT(DISTINCT PRODUCT_ID) as cnt
        FROM promotion_products
        GROUP BY PROMOTION_ID
    """)
    expected_counts = {row[0]: int(row[1]) for row in expected}
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_count = int(row.get('targeted_products_count', row.get('TARGETED_PRODUCTS_COUNT', 0)))
            expected_count = expected_counts.get(promo_id, 0)
            assert actual_count == expected_count, \
                f"Targeted products count mismatch for {promo_id}: expected {expected_count}, got {actual_count}"


def test_sorted_correctly():
    """Test that results are sorted by redemption_count desc, then promotion_name asc."""
    rows = []
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                'redemption_count': int(row.get('redemption_count', row.get('REDEMPTION_COUNT', 0))),
                'promotion_name': row.get('promotion_name', row.get('PROMOTION_NAME', ''))
            })

    for i in range(1, len(rows)):
        prev = rows[i-1]
        curr = rows[i]
        # Check descending redemption count
        if prev['redemption_count'] < curr['redemption_count']:
            pytest.fail(f"Not sorted by redemption_count desc: {prev['redemption_count']} < {curr['redemption_count']}")
        # If same redemption count, check ascending name
        elif prev['redemption_count'] == curr['redemption_count']:
            if prev['promotion_name'] > curr['promotion_name']:
                pytest.fail(f"Not sorted by promotion_name asc within same redemption count")


def test_roi_calculation():
    """Test that ROI is calculated correctly when discount > 0, and NULL when discount is 0."""
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            total_discount = safe_float(row.get('total_discount_given', row.get('TOTAL_DISCOUNT_GIVEN', '')), 0.0)
            roi_raw = row.get('roi_pct', row.get('ROI_PCT', ''))

            if total_discount == 0:
                # ROI should be null/empty when discount is 0
                # Accept various null representations: empty string, None, 'None', 'NULL', 'null'
                assert roi_raw in ('', None, 'None', 'NULL', 'null'), \
                    f"ROI should be NULL when discount is 0, got '{roi_raw}'"
            else:
                # ROI should be calculated
                roi = safe_float(roi_raw, None)
                if roi is None:
                    pytest.fail(f"ROI should have a value when discount > 0, got empty/null")
                lift = safe_float(row.get('estimated_lift', row.get('ESTIMATED_LIFT', '')), 0.0)
                expected_roi = ((lift - total_discount) / total_discount) * 100
                assert abs(roi - expected_roi) < 0.1, \
                    f"ROI calculation error: expected {expected_roi:.2f}, got {roi}"


def test_estimated_lift_calculation():
    """Test that estimated lift is redeemed_order_revenue - (baseline_daily_avg * duration)."""
    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            redeemed_revenue = safe_float(row.get('redeemed_order_revenue', row.get('REDEEMED_ORDER_REVENUE', '')), 0.0)
            baseline_daily = safe_float(row.get('baseline_daily_avg', row.get('BASELINE_DAILY_AVG', '')), 0.0)
            duration = int(row.get('promotion_duration_days', row.get('PROMOTION_DURATION_DAYS', 0)))
            lift = safe_float(row.get('estimated_lift', row.get('ESTIMATED_LIFT', '')), 0.0)

            expected_lift = redeemed_revenue - (baseline_daily * duration)
            assert abs(lift - expected_lift) < 1.0, \
                f"Lift calculation error: expected {expected_lift:.2f}, got {lift}"


def test_minimum_result_count():
    """Test that we have results for all promotions with redemptions AND targeted products."""
    conn, db_type = get_db_connection()

    # Count promotions that have both redemptions (excluding test orders) AND targeted products
    expected_count = execute_scalar(conn, db_type, """
        WITH promos_with_redemptions AS (
            SELECT DISTINCT pr.PROMOTION_ID
            FROM MARKETING.PROMOTION_REDEMPTIONS pr
            JOIN ORDERS.ORDERS o ON pr.ORDER_ID = o.ORDER_ID
            WHERE (o.TEST_ORDER_FLAG IS NULL OR UPPER(CAST(o.TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
              AND (o.SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(o.SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
              AND (o.INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(o.INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
        ),
        promos_with_targets AS (
            SELECT DISTINCT pp.PROMOTION_ID
            FROM MARKETING.PROMOTION_PRODUCTS pp
            LEFT JOIN PRODUCT.PRODUCTS p ON (
                (pp.PRODUCT_ID IS NOT NULL AND pp.PRODUCT_ID = p.PRODUCT_ID)
                OR (pp.BRAND_ID IS NOT NULL AND pp.BRAND_ID = p.BRAND_ID)
            )
            WHERE COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) IS NOT NULL
        )
        SELECT COUNT(*)
        FROM promos_with_redemptions r
        JOIN promos_with_targets t ON r.PROMOTION_ID = t.PROMOTION_ID
    """)
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        row_count = sum(1 for _ in reader)

    assert row_count == expected_count, \
        f"Expected {expected_count} promotions (with redemptions AND targeted products), got {row_count}"


def test_avg_discount_per_order_accuracy():
    """Test that average discount per order is calculated correctly (excluding test orders)."""
    conn, db_type = get_db_connection()

    expected = execute_query(conn, db_type, """
        SELECT pr.PROMOTION_ID, AVG(pr.DISCOUNT_AMOUNT) as avg_discount
        FROM MARKETING.PROMOTION_REDEMPTIONS pr
        JOIN ORDERS.ORDERS o ON pr.ORDER_ID = o.ORDER_ID
        WHERE (o.TEST_ORDER_FLAG IS NULL OR UPPER(CAST(o.TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(o.SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(o.INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
        GROUP BY pr.PROMOTION_ID
    """)
    expected_avgs = {row[0]: float(row[1]) for row in expected}
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_avg = safe_float(row.get('avg_discount_per_order', row.get('AVG_DISCOUNT_PER_ORDER', '')), 0.0)
            expected_avg = expected_avgs.get(promo_id, 0.0)
            assert abs(actual_avg - expected_avg) < 0.02, \
                f"Avg discount mismatch for {promo_id}: expected {expected_avg:.2f}, got {actual_avg:.2f}"


def test_redeemed_order_revenue_accuracy():
    """Test that redeemed_order_revenue matches sum of GRAND_TOTAL from redeemed orders (excluding test orders)."""
    conn, db_type = get_db_connection()

    expected = execute_query(conn, db_type, """
        SELECT pr.PROMOTION_ID, SUM(o.GRAND_TOTAL) as revenue
        FROM MARKETING.PROMOTION_REDEMPTIONS pr
        JOIN ORDERS.ORDERS o ON pr.ORDER_ID = o.ORDER_ID
        WHERE (o.TEST_ORDER_FLAG IS NULL OR UPPER(CAST(o.TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(o.SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
          AND (o.INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(o.INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
        GROUP BY pr.PROMOTION_ID
    """)
    expected_revenues = {row[0]: float(row[1]) for row in expected}
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_revenue = safe_float(row.get('redeemed_order_revenue', row.get('REDEEMED_ORDER_REVENUE', '')), 0.0)
            expected_revenue = expected_revenues.get(promo_id, 0.0)
            assert abs(actual_revenue - expected_revenue) < 0.02, \
                f"Redeemed order revenue mismatch for {promo_id}: expected {expected_revenue:.2f}, got {actual_revenue:.2f}"


def test_baseline_daily_avg_accuracy():
    """Test that baseline_daily_avg is correctly calculated from 365 days before promotion start.

    If no historical data exists for a promotion's targeted products, baseline should be 0.00.
    """
    conn, db_type = get_db_connection()

    # Get DB-specific date subtraction expression
    date_sub_expr = get_date_sub_expr(db_type, 'pd.start_date', 365)

    # Calculate expected baseline for each promotion
    # Promotions with no historical data will not appear in results - we treat missing as 0
    expected = execute_query(conn, db_type, f"""
        WITH valid_orders AS (
            SELECT ORDER_ID, CAST(ORDERED_AT AS DATE) as order_date
            FROM ORDERS.ORDERS
            WHERE (TEST_ORDER_FLAG IS NULL OR UPPER(CAST(TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
              AND (SAMPLE_ORDER_FLAG IS NULL OR UPPER(CAST(SAMPLE_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
              AND (INTERNAL_ORDER_FLAG IS NULL OR UPPER(CAST(INTERNAL_ORDER_FLAG AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
        ),
        promotion_products AS (
            SELECT DISTINCT
                pp.PROMOTION_ID,
                COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) as PRODUCT_ID
            FROM MARKETING.PROMOTION_PRODUCTS pp
            LEFT JOIN PRODUCT.PRODUCTS p ON (
                (pp.PRODUCT_ID IS NOT NULL AND pp.PRODUCT_ID = p.PRODUCT_ID)
                OR (pp.BRAND_ID IS NOT NULL AND pp.BRAND_ID = p.BRAND_ID)
            )
            WHERE COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) IS NOT NULL
        ),
        promo_dates AS (
            SELECT PROMOTION_ID, CAST(START_DATE AS DATE) as start_date
            FROM MARKETING.PROMOTIONS
        )
        SELECT
            pd.PROMOTION_ID,
            SUM(ol.LINE_TOTAL) / 365.0 as baseline_daily_avg
        FROM promo_dates pd
        JOIN promotion_products pp ON pd.PROMOTION_ID = pp.PROMOTION_ID
        JOIN ORDERS.ORDER_LINES ol ON pp.PRODUCT_ID = ol.PRODUCT_ID
        JOIN valid_orders vo ON ol.ORDER_ID = vo.ORDER_ID
        WHERE vo.order_date >= {date_sub_expr}
          AND vo.order_date < pd.start_date
        GROUP BY pd.PROMOTION_ID
    """)
    # Promotions with no historical data will be missing - treat as 0.0
    expected_baselines = {row[0]: float(row[1]) for row in expected}
    conn.close()

    with open(RESULT_PATH, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            promo_id = row.get('promotion_id', row.get('PROMOTION_ID', ''))
            actual_baseline = safe_float(row.get('baseline_daily_avg', row.get('BASELINE_DAILY_AVG', '')), 0.0)
            # If promo not in expected_baselines, it means no historical data - expect 0.0
            expected_baseline = expected_baselines.get(promo_id, 0.0)

            # Use percentage-based tolerance for larger values, absolute for small values
            if expected_baseline > 1.0:
                tolerance = expected_baseline * 0.05  # 5% tolerance
            else:
                tolerance = 0.1  # Absolute tolerance for small values

            assert abs(actual_baseline - expected_baseline) < tolerance, \
                f"Baseline daily avg mismatch for {promo_id}: expected {expected_baseline:.2f}, got {actual_baseline:.2f}"
