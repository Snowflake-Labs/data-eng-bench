"""
Tests for dbt-product-performance-metrics task.

This test suite validates the product performance analytics models including:
- Staging model: stg_order_lines__products
- Intermediate model: int_product_sales_summary
- Mart model: product_performance
"""

import subprocess
import os
import pytest
from decimal import Decimal
from pathlib import Path

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
            schema='product_analytics',
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


# ============ CONFIGURATION ============

SCHEMA = "main_product_analytics"

# Expected counts and totals
EXPECTED_TOTAL_PRODUCTS = 274
EXPECTED_TOTAL_LINE_ITEMS = 605
EXPECTED_TOTAL_ORDERS = 334
EXPECTED_TOTAL_NET_REVENUE = 118439.81

# Expected column names for the mart model in exact order (20 columns)
EXPECTED_COLUMNS = [
    'product_id',
    'product_name',
    'total_orders',
    'total_units_sold',
    'total_units_returned',
    'gross_revenue',
    'net_revenue',
    'return_rate',
    'avg_revenue_per_order',
    'revenue_rank',
    'revenue_contribution_pct',
    'cumulative_revenue_pct',
    'abc_class',
    'order_frequency_rank',
    'velocity_class',
    'discount_intensity',
    'margin_indicator',
    'price_position',
    'product_health_score',
    'performance_tier'
]

# Valid classification values
VALID_ABC_CLASSES = ['A', 'B', 'C']
VALID_VELOCITY_CLASSES = ['Fast Mover', 'Good Seller', 'Moderate', 'Slow Mover', 'Stagnant']
VALID_MARGIN_INDICATORS = ['Healthy', 'Moderate', 'Aggressive', 'Deep Discount']
VALID_PRICE_POSITIONS = ['Premium', 'Above Average', 'Average', 'Below Average', 'Budget']
VALID_PERFORMANCE_TIERS = ['Star Performer', 'Strong Performer', 'Average Performer', 'Underperformer', 'At Risk']

# Expected ABC distribution ranges
EXPECTED_ABC_COUNTS = {
    'A': (80, 90),
    'B': (70, 85),
    'C': (105, 120)
}

# Spot check products - (product_id, total_orders, net_revenue, abc_class, velocity_class, margin_indicator, price_position, health_score, performance_tier, revenue_rank)
SPOT_CHECK_PRODUCTS = [
    ('4da64ee9-0c43-49ed-ad7f-2b31aa9b7bf5', 41, 8014.35, 'A', 'Fast Mover', 'Healthy', 'Premium', 99, 'Star Performer', 1),
    ('f9b3c814-04f2-478f-b57e-d2211905e414', 39, 6640.70, 'A', 'Fast Mover', 'Healthy', 'Premium', 95, 'Star Performer', 2),
    ('c34c25f6-9584-41e3-878f-599ed044e9e5', 30, 5823.58, 'A', 'Fast Mover', 'Healthy', 'Premium', 100, 'Star Performer', 3),
    ('aed47cba-fce5-4e59-92db-117ba68fecc1', 1, 134.47, 'C', 'Slow Mover', 'Healthy', 'Above Average', 59, 'Average Performer', 200),
]


@pytest.fixture(scope="module")
def db_connection():
    """Create a database connection for testing."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


class TestModelExistence:
    """Tests for verifying that required models exist."""

    def test_staging_model_exists(self, db_connection):
        """Verify the staging model stg_order_lines__products exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE UPPER(table_schema) IN (
                UPPER('{SCHEMA}'), 'MAIN_STAGING',
                'MAIN_PRODUCT_ANALYTICS', 'MAIN_PRODUCT_ANALYTICS_STAGING',
                'PRODUCT_ANALYTICS', 'STAGING'
            )
            AND LOWER(table_name) = 'stg_order_lines__products'
        """)
        assert int(result) >= 1, "Staging model stg_order_lines__products does not exist"

    def test_intermediate_model_exists(self, db_connection):
        """Verify the intermediate model int_product_sales_summary exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE UPPER(table_schema) IN (
                UPPER('{SCHEMA}'), 'MAIN_INTERMEDIATE',
                'MAIN_PRODUCT_ANALYTICS', 'MAIN_PRODUCT_ANALYTICS_INTERMEDIATE',
                'PRODUCT_ANALYTICS', 'INTERMEDIATE'
            )
            AND LOWER(table_name) = 'int_product_sales_summary'
        """)
        assert int(result) >= 1, "Intermediate model int_product_sales_summary does not exist"

    def test_mart_model_exists(self, db_connection):
        """Verify the mart model product_performance exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE UPPER(table_schema) = UPPER('{SCHEMA}')
            AND LOWER(table_name) = 'product_performance'
        """)
        assert int(result) == 1, "Mart model product_performance does not exist"

    def test_mart_model_is_table(self, db_connection):
        """Verify the mart model is materialized as a table, not a view."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT table_type FROM information_schema.tables
            WHERE UPPER(table_schema) = UPPER('{SCHEMA}')
            AND LOWER(table_name) = 'product_performance'
        """)
        assert result in ('BASE TABLE', 'TABLE'), f"Mart model should be a TABLE, but is {result}"


class TestColumnStructure:
    """Tests for verifying column structure and order."""

    def test_mart_column_count(self, db_connection):
        """Verify the mart model has exactly 20 columns."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.columns
            WHERE UPPER(table_schema) = UPPER('{SCHEMA}')
            AND LOWER(table_name) = 'product_performance'
        """)
        assert int(result) == 20, f"Expected 20 columns, found {result}"

    def test_mart_column_names(self, db_connection):
        """Verify all required column names exist in the mart model."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT LOWER(column_name) FROM information_schema.columns
            WHERE UPPER(table_schema) = UPPER('{SCHEMA}')
            AND LOWER(table_name) = 'product_performance'
            ORDER BY ordinal_position
        """)
        actual_columns = [row[0] for row in result]
        assert actual_columns == EXPECTED_COLUMNS, f"Column mismatch. Expected: {EXPECTED_COLUMNS}, Actual: {actual_columns}"


class TestRowCounts:
    """Tests for verifying row counts."""

    def test_staging_row_count(self, db_connection):
        """Verify staging model has expected number of line items."""
        conn, db_type = db_connection
        # Try main_staging first, then SCHEMA
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_staging.stg_order_lines__products
            """)
        except:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.stg_order_lines__products
            """)
        assert int(result) == EXPECTED_TOTAL_LINE_ITEMS, f"Expected {EXPECTED_TOTAL_LINE_ITEMS} line items, found {result}"

    def test_mart_row_count(self, db_connection):
        """Verify mart model has expected number of products."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
        """)
        assert int(result) == EXPECTED_TOTAL_PRODUCTS, f"Expected {EXPECTED_TOTAL_PRODUCTS} products, found {result}"


class TestDataQuality:
    """Tests for data quality and integrity."""

    def test_no_null_product_ids(self, db_connection):
        """Verify there are no NULL product IDs in mart model."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
            WHERE product_id IS NULL
        """)
        assert int(result) == 0, f"Found {result} rows with NULL product_id"

    def test_no_negative_gross_revenues(self, db_connection):
        """Verify there are no negative gross revenues (net_revenue can be negative if discounts exceed gross)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
            WHERE gross_revenue < 0
        """)
        assert int(result) == 0, f"Found {result} rows with negative gross revenue"

    def test_total_net_revenue(self, db_connection):
        """Verify total net revenue matches expected value."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(net_revenue), 2) FROM {SCHEMA}.product_performance
        """)
        assert result is not None, "SUM(net_revenue) returned NULL"
        assert abs(float(result) - EXPECTED_TOTAL_NET_REVENUE) < 1.0, \
            f"Expected total net revenue {EXPECTED_TOTAL_NET_REVENUE}, got {result}"


class TestClassifications:
    """Tests for all classification columns."""

    def test_valid_abc_classes(self, db_connection):
        """Verify all abc_class values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT abc_class FROM {SCHEMA}.product_performance
        """)
        actual_classes = [row[0] for row in result]
        for cls in actual_classes:
            assert cls in VALID_ABC_CLASSES, f"Invalid abc_class: {cls}"

    def test_valid_velocity_classes(self, db_connection):
        """Verify all velocity_class values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT velocity_class FROM {SCHEMA}.product_performance
        """)
        actual_classes = [row[0] for row in result]
        for cls in actual_classes:
            assert cls in VALID_VELOCITY_CLASSES, f"Invalid velocity_class: {cls}"

    def test_valid_margin_indicators(self, db_connection):
        """Verify all margin_indicator values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT margin_indicator FROM {SCHEMA}.product_performance
        """)
        actual_indicators = [row[0] for row in result]
        for ind in actual_indicators:
            assert ind in VALID_MARGIN_INDICATORS, f"Invalid margin_indicator: {ind}"

    def test_valid_price_positions(self, db_connection):
        """Verify all price_position values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT price_position FROM {SCHEMA}.product_performance
        """)
        actual_positions = [row[0] for row in result]
        for pos in actual_positions:
            assert pos in VALID_PRICE_POSITIONS, f"Invalid price_position: {pos}"

    def test_valid_performance_tiers(self, db_connection):
        """Verify all performance_tier values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT performance_tier FROM {SCHEMA}.product_performance
        """)
        actual_tiers = [row[0] for row in result]
        for tier in actual_tiers:
            assert tier in VALID_PERFORMANCE_TIERS, f"Invalid performance_tier: {tier}"

    def test_velocity_class_distribution(self, db_connection):
        """Verify velocity classes have roughly equal distribution."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT velocity_class, COUNT(*) as cnt
            FROM {SCHEMA}.product_performance
            GROUP BY velocity_class
        """)
        counts = {row[0]: int(row[1]) for row in result}
        for cls in VALID_VELOCITY_CLASSES:
            assert cls in counts, f"Missing velocity class: {cls}"
            assert 50 <= counts[cls] <= 60, f"Unexpected count for {cls}: {counts[cls]}"


class TestHealthScore:
    """Tests for product_health_score calculations."""

    def test_health_score_range(self, db_connection):
        """Verify all health scores are within valid range."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT MIN(product_health_score), MAX(product_health_score)
            FROM {SCHEMA}.product_performance
        """)
        min_score, max_score = int(result[0][0]), int(result[0][1])
        assert min_score >= 5, f"Minimum health score {min_score} is below 5"
        assert max_score <= 100, f"Maximum health score {max_score} is above 100"

    def test_health_score_is_integer(self, db_connection):
        """Verify product_health_score is an integer type."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT data_type FROM information_schema.columns
            WHERE UPPER(table_schema) = UPPER('{SCHEMA}')
            AND LOWER(table_name) = 'product_performance'
            AND LOWER(column_name) = 'product_health_score'
        """)
        # Snowflake reports INTEGER as NUMBER, DuckDB reports as INTEGER/BIGINT
        assert result is not None, "product_health_score column not found"
        assert 'INT' in result.upper() or 'NUMBER' in result.upper(), \
            f"product_health_score should be INTEGER (or NUMBER in Snowflake), got {result}"

    def test_star_performer_threshold(self, db_connection):
        """Verify Star Performer products have health_score >= 80."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
            WHERE performance_tier = 'Star Performer' AND product_health_score < 80
        """)
        assert int(result) == 0, f"Found {result} Star Performers with score < 80"

    def test_at_risk_threshold(self, db_connection):
        """Verify At Risk products have health_score < 25."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
            WHERE performance_tier = 'At Risk' AND product_health_score >= 25
        """)
        assert int(result) == 0, f"Found {result} At Risk products with score >= 25"


class TestPricePosition:
    """Tests for price_position classification."""

    def test_all_price_positions_present(self, db_connection):
        """Verify all expected price positions are present."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT price_position FROM {SCHEMA}.product_performance
        """)
        actual_positions = set(row[0] for row in result)
        expected_positions = set(VALID_PRICE_POSITIONS)
        assert actual_positions == expected_positions, \
            f"Missing price positions: {expected_positions - actual_positions}"


class TestRankings:
    """Tests for ranking columns."""

    def test_revenue_rank_starts_at_one(self, db_connection):
        """Verify revenue_rank starts at 1."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT MIN(revenue_rank) FROM {SCHEMA}.product_performance
        """)
        assert int(result) == 1, f"Expected minimum revenue_rank to be 1, got {result}"

    def test_revenue_contribution_sums_to_100(self, db_connection):
        """Verify revenue contribution percentages sum to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(revenue_contribution_pct) FROM {SCHEMA}.product_performance
        """)
        assert result is not None, "SUM(revenue_contribution_pct) returned NULL"
        assert 99.5 <= float(result) <= 100.5, \
            f"Revenue contribution should sum to ~100%, got {result}"


class TestOrdering:
    """Tests for result ordering."""

    def test_ordered_by_net_revenue_desc(self, db_connection):
        """Verify results are ordered by net_revenue descending."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT net_revenue FROM {SCHEMA}.product_performance
            LIMIT 10
        """)
        revenues = [float(row[0]) for row in result]
        assert revenues == sorted(revenues, reverse=True), \
            "Results should be ordered by net_revenue descending"


class TestSpotChecks:
    """Spot check tests for specific products."""

    @pytest.mark.parametrize("product_id,expected_orders,expected_revenue,expected_abc,expected_velocity,expected_margin,expected_price,expected_score,expected_tier,expected_rank", SPOT_CHECK_PRODUCTS)
    def test_spot_check_product(self, db_connection, product_id, expected_orders, expected_revenue, expected_abc, expected_velocity, expected_margin, expected_price, expected_score, expected_tier, expected_rank):
        """Verify specific product metrics match expected values."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT total_orders, net_revenue, abc_class, velocity_class,
                   margin_indicator, price_position, product_health_score,
                   performance_tier, revenue_rank
            FROM {SCHEMA}.product_performance
            WHERE product_id = '{product_id}'
        """)

        assert len(result) > 0, f"Product {product_id} not found"
        row = result[0]

        actual_orders, actual_revenue, actual_abc, actual_velocity, actual_margin, actual_price, actual_score, actual_tier, actual_rank = row

        # Cast numeric values to handle Snowflake's Decimal return type
        assert int(actual_orders) == expected_orders, \
            f"Product {product_id}: expected orders {expected_orders}, got {actual_orders}"
        assert abs(float(actual_revenue) - expected_revenue) < 0.1, \
            f"Product {product_id}: expected revenue {expected_revenue}, got {actual_revenue}"
        assert actual_abc == expected_abc, \
            f"Product {product_id}: expected ABC class {expected_abc}, got {actual_abc}"
        assert actual_velocity == expected_velocity, \
            f"Product {product_id}: expected velocity {expected_velocity}, got {actual_velocity}"
        assert actual_margin == expected_margin, \
            f"Product {product_id}: expected margin {expected_margin}, got {actual_margin}"
        assert actual_price == expected_price, \
            f"Product {product_id}: expected price position {expected_price}, got {actual_price}"
        assert abs(int(actual_score) - expected_score) <= 2, \
            f"Product {product_id}: expected score {expected_score}, got {actual_score}"
        assert actual_tier == expected_tier, \
            f"Product {product_id}: expected tier {expected_tier}, got {actual_tier}"
        assert int(actual_rank) == expected_rank, \
            f"Product {product_id}: expected rank {expected_rank}, got {actual_rank}"


class TestDateFiltering:
    """Tests for date filtering in staging model."""

    def test_all_orders_in_2024(self, db_connection):
        """Verify all orders in staging are from 2024."""
        conn, db_type = db_connection
        # Try main_staging first, then SCHEMA
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_staging.stg_order_lines__products
                WHERE order_date < '2024-01-01' OR order_date >= '2025-01-01'
            """)
        except:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.stg_order_lines__products
                WHERE order_date < '2024-01-01' OR order_date >= '2025-01-01'
            """)
        assert int(result) == 0, f"Found {result} line items outside 2024"


class TestABCClassification:
    """Tests for ABC classification logic."""

    def test_class_a_cumulative_threshold(self, db_connection):
        """Verify class A products have cumulative_revenue_pct <= 70."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
            WHERE abc_class = 'A' AND cumulative_revenue_pct > 70.5
        """)
        assert int(result) == 0, f"Found {result} class A products above 70% threshold"

    def test_class_c_cumulative_threshold(self, db_connection):
        """Verify class C products have cumulative_revenue_pct > 90."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.product_performance
            WHERE abc_class = 'C' AND cumulative_revenue_pct < 89.5
        """)
        assert int(result) == 0, f"Found {result} class C products below 90% threshold"


class TestIdempotency:
    """Tests for idempotency and determinism."""

    def test_unique_product_ids(self, db_connection):
        """Verify all product IDs are unique in mart model."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) - COUNT(DISTINCT product_id)
            FROM {SCHEMA}.product_performance
        """)
        assert int(result) == 0, f"Found {result} duplicate product IDs"
