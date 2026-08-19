"""
Tests for dbt-basket-composition-analysis task.

This test suite validates the basket composition analytics models including:
- Staging model: stg_order_baskets (with order_month, order_half, order_quarter columns)
- Intermediate model: int_customer_basket_patterns (with H1/H2 metrics)
- Intermediate model: int_basket_transitions (with transition tracking between basket sizes)
- Mart model: basket_size_analysis (42 columns with scores, volatility, momentum, quadrants, transitions)

IMPORTANT: Tests must be fully deterministic. No CURRENT_DATE, NOW(), etc.
All functions have docstrings explaining their purpose.
"""

import subprocess
import os
import pytest
from decimal import Decimal

# ============ CONSTANTS ============

SCHEMA = "main_basket_analytics"

# Expected counts and totals
EXPECTED_TOTAL_ORDERS = 334
EXPECTED_TOTAL_CUSTOMERS = 143
EXPECTED_TOTAL_CATEGORIES = 4
EXPECTED_TOTAL_REVENUE = 119642.44

# Expected column names for the mart model in exact order (42 columns)
EXPECTED_COLUMNS = [
    'basket_size_category',
    'order_count',
    'total_revenue',
    'avg_basket_value',
    'avg_quantity_per_order',
    'total_customers',
    'avg_discount_per_order',
    'order_share_pct',
    'revenue_share_pct',
    'customer_share_pct',
    'avg_item_price',
    'revenue_per_customer',
    'size_index',
    'value_tier',
    'popularity_rank',
    'discount_efficiency',
    'avg_price_range',
    'h1_order_count',
    'h2_order_count',
    'h1_revenue',
    'h2_revenue',
    'order_growth_rate',
    'revenue_growth_rate',
    'growth_trend',
    'basket_efficiency_score',
    'growth_potential_score',
    'efficiency_tier',
    'growth_tier',
    'strategic_classification',
    'investment_priority',
    'quarter_order_volatility',
    'category_momentum',
    'efficiency_vs_avg',
    'rank_consistency',
    'avg_customer_orders',
    'relative_discount_rate',
    'composite_score',
    'performance_quadrant',
    'first_order_pct',
    'repeat_customer_pct',
    'upgrade_rate',
    'category_velocity_score'
]

# Valid classification values
VALID_SIZE_CATEGORIES = ['Single Item', 'Small Basket', 'Medium Basket', 'Large Basket']
VALID_VALUE_TIERS = ['Premium', 'Standard', 'Economy']
VALID_EFFICIENCY_TIERS = ['High Performance', 'Good Performance', 'Average Performance', 'Needs Improvement']
VALID_GROWTH_TIERS = ['High Potential', 'Moderate Potential', 'Low Potential', 'Saturated']
VALID_GROWTH_TRENDS = ['Accelerating', 'Growing', 'Stable', 'Declining', 'Contracting', None]
VALID_STRATEGIC_CLASSIFICATIONS = ['Core Revenue Driver', 'Growth Opportunity', 'Volume Leader', 'Niche Segment']
VALID_INVESTMENT_PRIORITIES = ['Star', 'Cash Cow', 'Question Mark', 'Underperformer', 'Stable Performer']
VALID_PERFORMANCE_QUADRANTS = ['Rising Star', 'Established Leader', 'High Potential', 'Needs Attention']

# Spot check categories with all key values
# Format: (category, order_count, total_revenue, avg_basket_value, h1_orders, h2_orders,
#          order_growth_rate, growth_trend, efficiency_score, growth_score,
#          efficiency_tier, growth_tier, strategic_class, investment_priority)
SPOT_CHECK_CATEGORIES = [
    ('Single Item', 178, 36051.16, 202.53, 66, 112, 69.7, 'Accelerating', 52, 77,
     'Average Performance', 'High Potential', 'Volume Leader', 'Question Mark'),
    ('Small Basket', 88, 38012.68, 431.96, 38, 50, 31.58, 'Accelerating', 62, 72,
     'Good Performance', 'High Potential', 'Niche Segment', 'Stable Performer'),
    ('Medium Basket', 62, 39966.13, 644.62, 24, 38, 58.33, 'Accelerating', 85, 78,
     'High Performance', 'High Potential', 'Core Revenue Driver', 'Star'),
    ('Large Basket', 6, 5612.47, 935.41, 3, 3, 0.0, 'Stable', 50, 51,
     'Average Performance', 'Moderate Potential', 'Growth Opportunity', 'Question Mark'),
]


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
    """Create a database connection based on DB_TYPE environment variable.
    Returns a (connection, db_type) tuple."""
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


def get_intermediate_schema():
    """Get the schema for intermediate models based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return SCHEMA
    return 'main'


# ============ HELPERS ============

def is_truthy(v):
    """Check if a value is truthy, handling cross-database boolean differences."""
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v == 1
    if isinstance(v, str):
        return v.lower() in ('1', 'true', 't')
    return bool(v)


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def db_connection():
    """
    Create a database connection for testing.

    Returns a (connection, db_type) tuple shared across all tests in the module.
    """
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


class TestModelExistence:
    """Tests for verifying that required models exist."""

    def test_staging_model_exists(self, db_connection):
        """Verify the staging model stg_order_baskets exists in the expected schema."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_staging')
            AND lower(table_name) = 'stg_order_baskets'
        """)
        assert int(result) >= 1, "Staging model stg_order_baskets does not exist"

    def test_intermediate_model_exists(self, db_connection):
        """Verify the intermediate model int_customer_basket_patterns exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate')
            AND lower(table_name) = 'int_customer_basket_patterns'
        """)
        assert int(result) >= 1, "Intermediate model int_customer_basket_patterns does not exist"

    def test_transitions_model_exists(self, db_connection):
        """Verify the intermediate model int_basket_transitions exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate')
            AND lower(table_name) = 'int_basket_transitions'
        """)
        assert int(result) >= 1, "Intermediate model int_basket_transitions does not exist"

    def test_cohorts_model_exists(self, db_connection):
        """Verify the intermediate model int_customer_cohorts exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate')
            AND lower(table_name) = 'int_customer_cohorts'
        """)
        assert int(result) >= 1, "Intermediate model int_customer_cohorts does not exist"

    def test_mart_model_exists(self, db_connection):
        """Verify the mart model basket_size_analysis exists in the correct schema."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'basket_size_analysis'
        """)
        assert int(result) == 1, "Mart model basket_size_analysis does not exist"

    def test_transition_summary_model_exists(self, db_connection):
        """Verify the mart model transition_summary exists in the correct schema."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'transition_summary'
        """)
        assert int(result) == 1, "Mart model transition_summary does not exist"

    def test_mart_model_is_table(self, db_connection):
        """Verify the mart model is materialized as a table, not a view."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT table_type FROM information_schema.tables
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'basket_size_analysis'
        """)
        assert result in ('BASE TABLE', 'TABLE'), f"Mart model should be a TABLE, but is {result}"


class TestColumnStructure:
    """Tests for verifying column structure and order."""

    def test_mart_column_count(self, db_connection):
        """Verify the mart model has exactly 42 columns."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'basket_size_analysis'
        """)
        assert int(result) == 42, f"Expected 42 columns, found {result}"

    def test_mart_column_names(self, db_connection):
        """Verify all required column names exist in the correct order."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'basket_size_analysis'
            ORDER BY ordinal_position
        """)
        actual_columns = [row[0] for row in result]
        assert actual_columns == EXPECTED_COLUMNS, f"Column mismatch. Expected: {EXPECTED_COLUMNS}, Actual: {actual_columns}"

    def test_staging_has_half_columns(self, db_connection):
        """Verify staging model has order_month, order_half, and order_quarter columns."""
        required = ['order_month', 'order_half', 'order_quarter']
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_staging')
            AND lower(table_name) = 'stg_order_baskets'
        """)
        actual = [row[0] for row in result]
        for col in required:
            assert col in actual, f"Missing column {col} in staging model"

    def test_intermediate_has_h1h2_columns(self, db_connection):
        """Verify intermediate model has H1/H2 columns."""
        required = ['h1_orders', 'h2_orders', 'h1_revenue', 'h2_revenue']
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate')
            AND lower(table_name) = 'int_customer_basket_patterns'
        """)
        actual = [row[0] for row in result]
        for col in required:
            assert col in actual, f"Missing column {col} in intermediate model"


class TestRowCounts:
    """Tests for verifying row counts across models."""

    def test_staging_row_count(self, db_connection):
        """Verify staging model has expected number of orders."""
        conn, db_type = db_connection
        for schema in [SCHEMA, 'main_staging']:
            try:
                result = execute_scalar(conn, db_type, f"""
                    SELECT COUNT(*) FROM {schema}.stg_order_baskets
                """)
                break
            except Exception:
                continue
        assert int(result) == EXPECTED_TOTAL_ORDERS, f"Expected {EXPECTED_TOTAL_ORDERS} orders, found {result}"

    def test_intermediate_row_count(self, db_connection):
        """Verify intermediate model has expected number of customers."""
        conn, db_type = db_connection
        for schema in [SCHEMA, 'main_intermediate']:
            try:
                result = execute_scalar(conn, db_type, f"""
                    SELECT COUNT(*) FROM {schema}.int_customer_basket_patterns
                """)
                break
            except Exception:
                continue
        assert int(result) == EXPECTED_TOTAL_CUSTOMERS, f"Expected {EXPECTED_TOTAL_CUSTOMERS} customers, found {result}"

    def test_mart_row_count(self, db_connection):
        """Verify mart model has exactly 4 basket size categories."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.basket_size_analysis
        """)
        assert int(result) == EXPECTED_TOTAL_CATEGORIES, f"Expected {EXPECTED_TOTAL_CATEGORIES} categories, found {result}"


class TestDataQuality:
    """Tests for data quality and integrity."""

    def test_no_null_categories(self, db_connection):
        """Verify there are no NULL basket size categories."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.basket_size_analysis
            WHERE basket_size_category IS NULL
        """)
        assert int(result) == 0, f"Found {result} rows with NULL basket_size_category"

    def test_total_revenue_matches(self, db_connection):
        """Verify total revenue matches expected value within tolerance."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(total_revenue), 2) FROM {SCHEMA}.basket_size_analysis
        """)
        assert abs(float(result) - EXPECTED_TOTAL_REVENUE) < 1.0, \
            f"Expected total revenue {EXPECTED_TOTAL_REVENUE}, got {result}"

    def test_total_orders_matches(self, db_connection):
        """Verify total orders sum matches expected value."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(order_count) FROM {SCHEMA}.basket_size_analysis
        """)
        assert int(result) == EXPECTED_TOTAL_ORDERS, f"Expected {EXPECTED_TOTAL_ORDERS} total orders, got {result}"


class TestClassifications:
    """Tests for classification values."""

    def test_valid_size_categories(self, db_connection):
        """Verify all basket_size_category values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT basket_size_category FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_SIZE_CATEGORIES, f"Invalid basket_size_category: {val}"

    def test_valid_value_tiers(self, db_connection):
        """Verify all value_tier values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT value_tier FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_VALUE_TIERS, f"Invalid value_tier: {val}"

    def test_valid_efficiency_tiers(self, db_connection):
        """Verify all efficiency_tier values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT efficiency_tier FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_EFFICIENCY_TIERS, f"Invalid efficiency_tier: {val}"

    def test_valid_growth_tiers(self, db_connection):
        """Verify all growth_tier values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT growth_tier FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_GROWTH_TIERS, f"Invalid growth_tier: {val}"

    def test_valid_growth_trends(self, db_connection):
        """Verify all growth_trend values are valid (including NULL)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT growth_trend FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_GROWTH_TRENDS, f"Invalid growth_trend: {val}"

    def test_valid_strategic_classifications(self, db_connection):
        """Verify all strategic_classification values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT strategic_classification FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_STRATEGIC_CLASSIFICATIONS, f"Invalid strategic_classification: {val}"

    def test_valid_investment_priorities(self, db_connection):
        """Verify all investment_priority values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT investment_priority FROM {SCHEMA}.basket_size_analysis
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_INVESTMENT_PRIORITIES, f"Invalid investment_priority: {val}"


class TestPercentages:
    """Tests for percentage calculations."""

    def test_order_share_sums_to_100(self, db_connection):
        """Verify order share percentages sum to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(order_share_pct) FROM {SCHEMA}.basket_size_analysis
        """)
        assert 99.5 <= float(result) <= 100.5, \
            f"Order share should sum to ~100%, got {result}"

    def test_revenue_share_sums_to_100(self, db_connection):
        """Verify revenue share percentages sum to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(revenue_share_pct) FROM {SCHEMA}.basket_size_analysis
        """)
        assert 99.5 <= float(result) <= 100.5, \
            f"Revenue share should sum to ~100%, got {result}"


class TestHalfBasedMetrics:
    """Tests for H1/H2 half-based metrics."""

    def test_h1_h2_order_count_sum(self, db_connection):
        """Verify H1 + H2 order counts equal total order count."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, order_count, h1_order_count, h2_order_count
            FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            category, total, h1, h2 = row
            assert int(total) == int(h1) + int(h2), f"{category}: order_count {total} != h1 {h1} + h2 {h2}"

    def test_h1_h2_revenue_sum(self, db_connection):
        """Verify H1 + H2 revenue approximately equals total revenue."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, total_revenue, h1_revenue, h2_revenue
            FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            category, total, h1, h2 = row
            expected_sum = float(h1) + float(h2)
            assert abs(float(total) - expected_sum) < 1.0, \
                f"{category}: total_revenue {total} != h1 {h1} + h2 {h2}"

    def test_order_growth_rate_calculation(self, db_connection):
        """Verify order_growth_rate is calculated correctly."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, h1_order_count, h2_order_count, order_growth_rate
            FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            category, h1, h2, growth = row
            if int(h1) == 0:
                assert growth is None, f"{category}: growth rate should be NULL when h1=0"
            else:
                expected = round((int(h2) - int(h1)) * 100.0 / int(h1), 2)
                assert abs(float(growth) - expected) < 0.1, \
                    f"{category}: expected growth {expected}, got {growth}"


class TestScoreRanges:
    """Tests for score ranges and calculations."""

    def test_efficiency_score_range(self, db_connection):
        """Verify efficiency scores are within valid range (5-100)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.basket_size_analysis
            WHERE basket_efficiency_score < 5 OR basket_efficiency_score > 100
        """)
        assert int(result) == 0, f"Found {result} rows with efficiency score outside 5-100 range"

    def test_growth_score_range(self, db_connection):
        """Verify growth potential scores are within valid range (5-100)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.basket_size_analysis
            WHERE growth_potential_score < 5 OR growth_potential_score > 100
        """)
        assert int(result) == 0, f"Found {result} rows with growth score outside 5-100 range"

    def test_efficiency_tier_consistency(self, db_connection):
        """Verify efficiency tier matches score thresholds."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_efficiency_score, efficiency_tier
            FROM {SCHEMA}.basket_size_analysis
        """)
        for score, tier in result:
            score_val = int(score)
            if score_val >= 75:
                assert tier == 'High Performance', f"Score {score_val} should be High Performance"
            elif score_val >= 55:
                assert tier == 'Good Performance', f"Score {score_val} should be Good Performance"
            elif score_val >= 35:
                assert tier == 'Average Performance', f"Score {score_val} should be Average Performance"
            else:
                assert tier == 'Needs Improvement', f"Score {score_val} should be Needs Improvement"

    def test_growth_tier_consistency(self, db_connection):
        """Verify growth tier matches score thresholds."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT growth_potential_score, growth_tier
            FROM {SCHEMA}.basket_size_analysis
        """)
        for score, tier in result:
            score_val = int(score)
            if score_val >= 70:
                assert tier == 'High Potential', f"Score {score_val} should be High Potential"
            elif score_val >= 50:
                assert tier == 'Moderate Potential', f"Score {score_val} should be Moderate Potential"
            elif score_val >= 30:
                assert tier == 'Low Potential', f"Score {score_val} should be Low Potential"
            else:
                assert tier == 'Saturated', f"Score {score_val} should be Saturated"


class TestOrdering:
    """Tests for result ordering."""

    def test_ordered_by_order_count_desc(self, db_connection):
        """Verify results are ordered by order_count descending."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT order_count FROM {SCHEMA}.basket_size_analysis
        """)
        counts = [int(row[0]) for row in result]
        assert counts == sorted(counts, reverse=True), \
            "Results should be ordered by order_count descending"


class TestSpotChecks:
    """Spot check tests for specific categories with all key metrics."""

    @pytest.mark.parametrize("category,exp_orders,exp_revenue,exp_avg_value,exp_h1,exp_h2,exp_order_growth,exp_growth_trend,exp_eff_score,exp_growth_score,exp_eff_tier,exp_growth_tier,exp_strategic,exp_investment", SPOT_CHECK_CATEGORIES)
    def test_spot_check_category(self, db_connection, category, exp_orders, exp_revenue, exp_avg_value,
                                  exp_h1, exp_h2, exp_order_growth, exp_growth_trend,
                                  exp_eff_score, exp_growth_score, exp_eff_tier, exp_growth_tier,
                                  exp_strategic, exp_investment):
        """
        Verify specific category metrics match expected values.

        Tests all key metrics including order counts, revenue, H1/H2 splits,
        growth rates, scores, tiers, and classifications.
        """
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT order_count, total_revenue, avg_basket_value,
                   h1_order_count, h2_order_count, order_growth_rate, growth_trend,
                   basket_efficiency_score, growth_potential_score,
                   efficiency_tier, growth_tier, strategic_classification, investment_priority
            FROM {SCHEMA}.basket_size_analysis
            WHERE basket_size_category = '{category}'
        """)

        assert result is not None and len(result) > 0, f"Category {category} not found"
        row = result[0]

        (actual_orders, actual_revenue, actual_avg_value, actual_h1, actual_h2,
         actual_order_growth, actual_growth_trend, actual_eff_score, actual_growth_score,
         actual_eff_tier, actual_growth_tier, actual_strategic, actual_investment) = row

        assert int(actual_orders) == exp_orders, \
            f"{category}: expected orders {exp_orders}, got {actual_orders}"
        assert abs(float(actual_revenue) - exp_revenue) < 0.1, \
            f"{category}: expected revenue {exp_revenue}, got {actual_revenue}"
        assert abs(float(actual_avg_value) - exp_avg_value) < 0.1, \
            f"{category}: expected avg_value {exp_avg_value}, got {actual_avg_value}"
        assert int(actual_h1) == exp_h1, \
            f"{category}: expected h1_order_count {exp_h1}, got {actual_h1}"
        assert int(actual_h2) == exp_h2, \
            f"{category}: expected h2_order_count {exp_h2}, got {actual_h2}"

        # Growth rate comparison with tight tolerance
        if exp_order_growth is not None:
            assert abs(float(actual_order_growth) - exp_order_growth) < 0.1, \
                f"{category}: expected order_growth_rate {exp_order_growth}, got {actual_order_growth}"
        else:
            assert actual_order_growth is None, \
                f"{category}: expected order_growth_rate NULL, got {actual_order_growth}"

        assert actual_growth_trend == exp_growth_trend, \
            f"{category}: expected growth_trend '{exp_growth_trend}', got '{actual_growth_trend}'"
        assert int(actual_eff_score) == exp_eff_score, \
            f"{category}: expected efficiency_score {exp_eff_score}, got {actual_eff_score}"
        assert int(actual_growth_score) == exp_growth_score, \
            f"{category}: expected growth_score {exp_growth_score}, got {actual_growth_score}"
        assert actual_eff_tier == exp_eff_tier, \
            f"{category}: expected efficiency_tier '{exp_eff_tier}', got '{actual_eff_tier}'"
        assert actual_growth_tier == exp_growth_tier, \
            f"{category}: expected growth_tier '{exp_growth_tier}', got '{actual_growth_tier}'"
        assert actual_strategic == exp_strategic, \
            f"{category}: expected strategic '{exp_strategic}', got '{actual_strategic}'"
        assert actual_investment == exp_investment, \
            f"{category}: expected investment '{exp_investment}', got '{actual_investment}'"


class TestIdempotency:
    """Tests for idempotency and determinism."""

    def test_unique_categories(self, db_connection):
        """Verify all basket size categories are unique in mart model."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) - COUNT(DISTINCT basket_size_category)
            FROM {SCHEMA}.basket_size_analysis
        """)
        assert int(result) == 0, f"Found {result} duplicate categories"

    def test_all_categories_present(self, db_connection):
        """Verify all expected basket size categories are present."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT basket_size_category FROM {SCHEMA}.basket_size_analysis
        """)
        actual_categories = set(row[0] for row in result)
        expected_categories = set(VALID_SIZE_CATEGORIES)
        assert actual_categories == expected_categories, \
            f"Missing categories: {expected_categories - actual_categories}"


class TestPreciseCalculations:
    """Tests for precise calculation verification."""

    def test_size_index_calculation(self, db_connection):
        """Verify size_index is calculated as revenue_share_pct / order_share_pct."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, order_share_pct, revenue_share_pct, size_index
            FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            category, order_pct, rev_pct, size_idx = row
            expected = round(float(rev_pct) / float(order_pct), 2)
            assert abs(float(size_idx) - expected) < 0.02, \
                f"{category}: size_index should be {expected}, got {size_idx}"

    def test_revenue_per_customer_calculation(self, db_connection):
        """Verify revenue_per_customer is calculated as total_revenue / total_customers."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, total_revenue, total_customers, revenue_per_customer
            FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            category, revenue, customers, rpc = row
            expected = round(float(revenue) / int(customers), 2)
            assert abs(float(rpc) - expected) < 0.5, \
                f"{category}: revenue_per_customer should be {expected}, got {rpc}"

    def test_popularity_rank_values(self, db_connection):
        """Verify popularity ranks are 1-4 with no duplicates."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT popularity_rank FROM {SCHEMA}.basket_size_analysis
            ORDER BY popularity_rank
        """)
        ranks = [int(row[0]) for row in result]
        assert ranks == [1, 2, 3, 4], f"Expected ranks [1,2,3,4], got {ranks}"

    def test_exact_order_counts(self, db_connection):
        """Verify exact order counts for all categories."""
        expected_counts = {
            'Single Item': 178,
            'Small Basket': 88,
            'Medium Basket': 62,
            'Large Basket': 6
        }
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, order_count
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, count in result:
            assert int(count) == expected_counts[category], \
                f"{category}: expected {expected_counts[category]} orders, got {count}"

    def test_customer_share_calculation(self, db_connection):
        """Verify customer_share_pct is calculated relative to total unique customers."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT SUM(total_customers) as sum_customers,
                   SUM(customer_share_pct) as sum_pct
            FROM {SCHEMA}.basket_size_analysis
        """)
        sum_customers, sum_pct = result[0]
        # Sum of customer_share_pct should be > 100 since customers can be in multiple categories
        assert float(sum_pct) >= 100, \
            f"Sum of customer_share_pct should be >= 100 (customers can appear in multiple categories), got {sum_pct}"

    def test_exact_revenue_values(self, db_connection):
        """Verify exact revenue values for all categories."""
        expected_revenues = {
            'Single Item': 36051.16,
            'Small Basket': 38012.68,
            'Medium Basket': 39966.13,
            'Large Basket': 5612.47
        }
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, total_revenue
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, revenue in result:
            expected = expected_revenues[category]
            assert abs(float(revenue) - expected) < 0.1, \
                f"{category}: expected revenue {expected}, got {revenue}"

    def test_revenue_growth_rate_consistency(self, db_connection):
        """Verify revenue_growth_rate is calculated correctly from H1/H2 revenue."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, h1_revenue, h2_revenue, revenue_growth_rate
            FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            category, h1_rev, h2_rev, growth = row
            if h1_rev is None or float(h1_rev) == 0:
                assert growth is None, \
                    f"{category}: revenue_growth_rate should be NULL when h1_revenue is 0"
            else:
                expected = round((float(h2_rev) - float(h1_rev)) * 100.0 / float(h1_rev), 2)
                assert abs(float(growth) - expected) < 0.5, \
                    f"{category}: revenue_growth_rate should be {expected}, got {growth}"

    def test_discount_efficiency_values(self, db_connection):
        """Verify discount_efficiency calculation is reasonable."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, total_revenue, discount_efficiency
            FROM {SCHEMA}.basket_size_analysis
            WHERE discount_efficiency IS NOT NULL
        """)
        for category, revenue, eff in result:
            # discount_efficiency should be positive and reasonable
            assert float(eff) > 0, f"{category}: discount_efficiency should be positive"
            assert float(eff) <= float(revenue), \
                f"{category}: discount_efficiency {eff} seems unreasonable for revenue {revenue}"

    def test_quarter_order_volatility_non_negative(self, db_connection):
        """Verify quarter_order_volatility is non-negative (stddev cannot be negative)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, quarter_order_volatility
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, volatility in result:
            assert float(volatility) >= 0, \
                f"{category}: quarter_order_volatility should be non-negative, got {volatility}"

    def test_category_momentum_null_handling(self, db_connection):
        """Verify category_momentum is NULL when either growth rate is NULL."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, order_growth_rate, revenue_growth_rate, category_momentum
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, order_gr, rev_gr, momentum in result:
            if order_gr is None or rev_gr is None:
                assert momentum is None, \
                    f"{category}: category_momentum should be NULL when growth rate is NULL"
            else:
                assert momentum is not None, \
                    f"{category}: category_momentum should not be NULL when both growth rates exist"

    def test_category_momentum_calculation(self, db_connection):
        """Verify category_momentum formula: order_growth_rate * 0.4 + revenue_growth_rate * 0.6."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, order_growth_rate, revenue_growth_rate, category_momentum
            FROM {SCHEMA}.basket_size_analysis
            WHERE category_momentum IS NOT NULL
        """)
        for category, order_gr, rev_gr, momentum in result:
            expected = round(float(order_gr) * 0.4 + float(rev_gr) * 0.6, 2)
            assert abs(float(momentum) - expected) < 0.1, \
                f"{category}: category_momentum should be {expected}, got {momentum}"

    def test_efficiency_vs_avg_sums_to_zero(self, db_connection):
        """Verify efficiency_vs_avg values sum to approximately zero (deviations from mean)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(efficiency_vs_avg) FROM {SCHEMA}.basket_size_analysis
        """)
        assert abs(float(result)) < 0.5, \
            f"Sum of efficiency_vs_avg should be ~0, got {result}"

    def test_efficiency_vs_avg_calculation(self, db_connection):
        """Verify efficiency_vs_avg is score minus average score."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_efficiency_score, efficiency_vs_avg,
                   AVG(basket_efficiency_score) OVER () as avg_score
            FROM {SCHEMA}.basket_size_analysis
        """)
        for score, vs_avg, avg_score in result:
            expected = round(float(score) - float(avg_score), 2)
            assert abs(float(vs_avg) - expected) < 0.1, \
                f"efficiency_vs_avg should be {expected}, got {vs_avg}"

    def test_rank_consistency_non_negative(self, db_connection):
        """Verify rank_consistency is non-negative (absolute difference)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, rank_consistency
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, consistency in result:
            assert int(consistency) >= 0, \
                f"{category}: rank_consistency should be non-negative, got {consistency}"

    def test_rank_consistency_calculation(self, db_connection):
        """Verify rank_consistency is |popularity_rank - revenue_rank|."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, popularity_rank,
                   DENSE_RANK() OVER (ORDER BY total_revenue DESC) as revenue_rank,
                   rank_consistency
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, pop_rank, rev_rank, consistency in result:
            expected = abs(int(pop_rank) - int(rev_rank))
            assert int(consistency) == expected, \
                f"{category}: rank_consistency should be {expected}, got {consistency}"

    def test_avg_customer_orders_calculation(self, db_connection):
        """Verify avg_customer_orders = order_count / total_customers."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, order_count, total_customers, avg_customer_orders
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, orders, customers, avg_orders in result:
            expected = round(float(orders) / float(customers), 2)
            assert abs(float(avg_orders) - expected) < 0.01, \
                f"{category}: avg_customer_orders should be {expected}, got {avg_orders}"

    def test_relative_discount_rate_calculation(self, db_connection):
        """Verify relative_discount_rate is category discount as % of overall average."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, avg_discount_per_order,
                   AVG(avg_discount_per_order) OVER () as overall_avg,
                   relative_discount_rate
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, discount, overall_avg, rel_rate in result:
            expected = round(float(discount) * 100.0 / float(overall_avg), 2)
            assert abs(float(rel_rate) - expected) < 0.5, \
                f"{category}: relative_discount_rate should be {expected}, got {rel_rate}"

    def test_composite_score_calculation(self, db_connection):
        """Verify composite_score = (efficiency + growth) / 2 rounded."""
        import math
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, basket_efficiency_score, growth_potential_score, composite_score
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, eff, growth, composite in result:
            # SQL uses traditional rounding (round half up), not Python's banker's rounding
            avg_score = (int(eff) + int(growth)) / 2.0
            expected = math.floor(avg_score + 0.5)  # Traditional rounding
            assert int(composite) == expected, \
                f"{category}: composite_score should be {expected}, got {composite}"

    def test_performance_quadrant_values(self, db_connection):
        """Verify performance_quadrant values are valid."""
        valid_quadrants = ['Rising Star', 'Established Leader', 'High Potential', 'Needs Attention']
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT performance_quadrant FROM {SCHEMA}.basket_size_analysis
        """)
        for row in result:
            assert row[0] in valid_quadrants, f"Invalid performance_quadrant: {row[0]}"

    def test_performance_quadrant_logic(self, db_connection):
        """Verify performance_quadrant classification logic."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, efficiency_vs_avg, growth_potential_score, performance_quadrant
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, eff_vs_avg, growth_score, quadrant in result:
            eff_positive = float(eff_vs_avg) > 0
            high_growth = int(growth_score) >= 60

            if eff_positive and high_growth:
                expected = 'Rising Star'
            elif eff_positive and not high_growth:
                expected = 'Established Leader'
            elif not eff_positive and high_growth:
                expected = 'High Potential'
            else:
                expected = 'Needs Attention'

            assert quadrant == expected, \
                f"{category}: expected '{expected}', got '{quadrant}' (eff_vs_avg={eff_vs_avg}, growth={growth_score})"


class TestBasketTransitions:
    """Tests for the int_basket_transitions model."""

    def test_transitions_has_required_columns(self, db_connection):
        """Verify transitions model has all required columns."""
        required = ['from_category', 'to_category', 'transition_count', 'transition_pct',
                    'avg_days_between', 'is_upgrade', 'is_downgrade']
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate')
            AND lower(table_name) = 'int_basket_transitions'
        """)
        actual = [row[0] for row in result]
        for col in required:
            assert col in actual, f"Missing column {col} in transitions model"

    def test_transitions_categories_valid(self, db_connection):
        """Verify all from_category and to_category values are valid basket size categories."""
        conn, db_type = db_connection
        for schema in [SCHEMA, 'main_intermediate']:
            try:
                result = execute_query(conn, db_type, f"""
                    SELECT DISTINCT from_category FROM {schema}.int_basket_transitions
                    UNION
                    SELECT DISTINCT to_category FROM {schema}.int_basket_transitions
                """)
                break
            except Exception:
                continue
        valid_cats = ['Single Item', 'Small Basket', 'Medium Basket', 'Large Basket']
        for row in result:
            assert row[0] in valid_cats, f"Invalid category in transitions: {row[0]}"

    def test_transitions_pct_sums_to_100(self, db_connection):
        """Verify transition percentages sum to approximately 100."""
        conn, db_type = db_connection
        for schema in [SCHEMA, 'main_intermediate']:
            try:
                result = execute_scalar(conn, db_type, f"""
                    SELECT SUM(transition_pct) FROM {schema}.int_basket_transitions
                """)
                break
            except Exception:
                continue
        assert 99.5 <= float(result) <= 100.5, f"Transition percentages should sum to ~100%, got {result}"

    def test_upgrade_downgrade_logic(self, db_connection):
        """Verify is_upgrade and is_downgrade follow category size order."""
        category_order = {'Single Item': 1, 'Small Basket': 2, 'Medium Basket': 3, 'Large Basket': 4}
        conn, db_type = db_connection
        for schema in [SCHEMA, 'main_intermediate']:
            try:
                result = execute_query(conn, db_type, f"""
                    SELECT from_category, to_category, is_upgrade, is_downgrade
                    FROM {schema}.int_basket_transitions
                """)
                break
            except Exception:
                continue
        for from_cat, to_cat, is_upgrade_val, is_downgrade_val in result:
            from_order = category_order[from_cat]
            to_order = category_order[to_cat]
            if to_order > from_order:
                assert is_truthy(is_upgrade_val), f"{from_cat}->{to_cat} should be upgrade"
            elif to_order < from_order:
                assert is_truthy(is_downgrade_val), f"{from_cat}->{to_cat} should be downgrade"


class TestNewColumns:
    """Tests for the new columns added in the enhanced version."""

    def test_first_order_pct_range(self, db_connection):
        """Verify first_order_pct is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, first_order_pct
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, pct in result:
            assert 0 <= float(pct) <= 100, \
                f"{category}: first_order_pct should be 0-100, got {pct}"

    def test_repeat_customer_pct_range(self, db_connection):
        """Verify repeat_customer_pct is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, repeat_customer_pct
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, pct in result:
            assert 0 <= float(pct) <= 100, \
                f"{category}: repeat_customer_pct should be 0-100, got {pct}"

    def test_upgrade_rate_range_or_null(self, db_connection):
        """Verify upgrade_rate is between 0 and 100, or NULL for categories with no outgoing transitions."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, upgrade_rate
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, rate in result:
            if rate is not None:
                assert 0 <= float(rate) <= 100, \
                    f"{category}: upgrade_rate should be 0-100, got {rate}"

    def test_category_velocity_score_range(self, db_connection):
        """Verify category_velocity_score is within valid range (0-100)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, category_velocity_score
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, score in result:
            assert 0 <= int(score) <= 100, \
                f"{category}: category_velocity_score should be 0-100, got {score}"

    def test_velocity_score_components(self, db_connection):
        """Verify velocity score calculation is consistent with component logic."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT basket_size_category, first_order_pct, repeat_customer_pct, category_velocity_score
            FROM {SCHEMA}.basket_size_analysis
        """)
        for category, first_pct, repeat_pct, velocity in result:
            # Calculate expected first-order component
            first_pct_val = float(first_pct)
            if first_pct_val >= 40:
                first_pts = 30
            elif first_pct_val >= 25:
                first_pts = 20
            elif first_pct_val >= 10:
                first_pts = 10
            else:
                first_pts = 5

            # Calculate expected retention component
            repeat_pct_val = float(repeat_pct)
            if repeat_pct_val >= 70:
                retain_pts = 30
            elif repeat_pct_val >= 50:
                retain_pts = 22
            elif repeat_pct_val >= 30:
                retain_pts = 15
            else:
                retain_pts = 8

            # Velocity score should be at least first_pts + retain_pts (transition component adds 20 or 40)
            min_expected = first_pts + retain_pts + 20
            max_expected = first_pts + retain_pts + 40
            assert min_expected <= int(velocity) <= max_expected, \
                f"{category}: velocity_score {velocity} not in expected range [{min_expected}, {max_expected}]"


class TestTransitionSummary:
    """Tests for the transition_summary mart model."""

    def test_transition_summary_has_required_columns(self, db_connection):
        """Verify transition_summary model has all required columns in order."""
        expected = ['category', 'total_incoming_transitions', 'total_outgoing_transitions',
                    'net_transition_flow', 'retention_transitions', 'inflow_rate',
                    'outflow_rate', 'transition_balance']
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'transition_summary'
            ORDER BY ordinal_position
        """)
        actual = [row[0] for row in result]
        assert actual == expected, f"Column mismatch. Expected: {expected}, Actual: {actual}"

    def test_transition_summary_row_count(self, db_connection):
        """Verify transition_summary has exactly 4 rows (one per basket size category)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.transition_summary
        """)
        assert int(result) == 4, f"Expected 4 rows in transition_summary, found {result}"

    def test_transition_summary_ordered_alphabetically(self, db_connection):
        """Verify transition_summary is ordered alphabetically by category."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT category FROM {SCHEMA}.transition_summary
        """)
        categories = [row[0] for row in result]
        expected_order = ['Large Basket', 'Medium Basket', 'Single Item', 'Small Basket']
        assert categories == expected_order, f"Expected alphabetical order {expected_order}, got {categories}"

    def test_net_transition_flow_calculation(self, db_connection):
        """Verify net_transition_flow = incoming - outgoing."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT category, total_incoming_transitions, total_outgoing_transitions, net_transition_flow
            FROM {SCHEMA}.transition_summary
        """)
        for category, incoming, outgoing, net in result:
            expected = int(incoming) - int(outgoing)
            assert int(net) == expected, \
                f"{category}: net_transition_flow should be {expected}, got {net}"

    def test_transition_balance_logic(self, db_connection):
        """Verify transition_balance classification is correct."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT category, net_transition_flow, transition_balance
            FROM {SCHEMA}.transition_summary
        """)
        for category, net, balance in result:
            net_val = int(net)
            if net_val > 0:
                expected = 'Net Gainer'
            elif net_val < 0:
                expected = 'Net Loser'
            else:
                expected = 'Balanced'
            assert balance == expected, \
                f"{category}: expected '{expected}' for net_flow={net_val}, got '{balance}'"

    def test_inflow_outflow_rates_valid(self, db_connection):
        """Verify inflow_rate and outflow_rate are between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT category, inflow_rate, outflow_rate
            FROM {SCHEMA}.transition_summary
        """)
        for category, inflow, outflow in result:
            assert 0 <= float(inflow) <= 100, \
                f"{category}: inflow_rate should be 0-100, got {inflow}"
            assert 0 <= float(outflow) <= 100, \
                f"{category}: outflow_rate should be 0-100, got {outflow}"

    def test_transition_summary_is_table(self, db_connection):
        """Verify the transition_summary model is materialized as a table."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT table_type FROM information_schema.tables
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'transition_summary'
        """)
        assert result in ('BASE TABLE', 'TABLE'), f"transition_summary should be a TABLE, but is {result}"


class TestCustomerCohorts:
    """Tests for the int_customer_cohorts model."""

    def test_cohorts_has_required_columns(self, db_connection):
        """Verify cohorts model has all required columns."""
        expected = ['cohort_category', 'cohort_size', 'total_cohort_orders', 'total_cohort_revenue',
                    'avg_orders_per_customer', 'repeat_rate', 'upgrade_rate', 'downgrade_rate',
                    'same_category_rate', 'cohort_share_pct']
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA}'
            AND lower(table_name) = 'int_customer_cohorts'
            ORDER BY ordinal_position
        """)
        actual = [row[0] for row in result]
        assert actual == expected, f"Column mismatch. Expected: {expected}, Actual: {actual}"

    def test_cohorts_row_count(self, db_connection):
        """Verify cohorts has 3-4 rows (one per basket size category that has first-time customers)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_customer_cohorts
        """)
        # Not all categories may have customers whose first order was in that category
        assert 3 <= int(result) <= 4, f"Expected 3-4 rows in cohorts, found {result}"

    def test_cohorts_ordered_by_size_desc(self, db_connection):
        """Verify cohorts is ordered by cohort_size descending."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT cohort_size FROM {SCHEMA}.int_customer_cohorts
        """)
        sizes = [int(row[0]) for row in result]
        assert sizes == sorted(sizes, reverse=True), f"Cohorts should be ordered by size desc, got {sizes}"

    def test_cohort_share_sums_to_100(self, db_connection):
        """Verify cohort_share_pct sums to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(cohort_share_pct) FROM {SCHEMA}.int_customer_cohorts
        """)
        assert 99.5 <= float(result) <= 100.5, f"Cohort shares should sum to ~100%, got {result}"

    def test_cohort_size_equals_total_customers(self, db_connection):
        """Verify sum of cohort_size equals total unique customers."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(cohort_size) FROM {SCHEMA}.int_customer_cohorts
        """)
        assert int(result) == EXPECTED_TOTAL_CUSTOMERS, \
            f"Sum of cohort sizes should be {EXPECTED_TOTAL_CUSTOMERS}, got {result}"

    def test_rates_sum_to_100_or_null(self, db_connection):
        """Verify upgrade_rate + downgrade_rate + same_category_rate = 100 (or all NULL)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT cohort_category, upgrade_rate, downgrade_rate, same_category_rate
            FROM {SCHEMA}.int_customer_cohorts
        """)
        for cohort, upgrade, downgrade, same in result:
            if upgrade is None and downgrade is None and same is None:
                continue  # All NULL is valid for cohorts with no repeat orders
            total = float(upgrade or 0) + float(downgrade or 0) + float(same or 0)
            assert 99.0 <= total <= 101.0, \
                f"{cohort}: rates should sum to ~100%, got {total} (up={upgrade}, down={downgrade}, same={same})"

    def test_repeat_rate_range(self, db_connection):
        """Verify repeat_rate is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT cohort_category, repeat_rate FROM {SCHEMA}.int_customer_cohorts
        """)
        for cohort, rate in result:
            assert 0 <= float(rate) <= 100, f"{cohort}: repeat_rate should be 0-100, got {rate}"

    def test_avg_orders_at_least_one(self, db_connection):
        """Verify avg_orders_per_customer is at least 1 (everyone has at least their first order)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT cohort_category, avg_orders_per_customer FROM {SCHEMA}.int_customer_cohorts
        """)
        for cohort, avg in result:
            assert float(avg) >= 1.0, f"{cohort}: avg_orders should be >= 1, got {avg}"

    def test_total_orders_matches_expected(self, db_connection):
        """Verify sum of total_cohort_orders equals expected total orders."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(total_cohort_orders) FROM {SCHEMA}.int_customer_cohorts
        """)
        assert int(result) == EXPECTED_TOTAL_ORDERS, \
            f"Sum of cohort orders should be {EXPECTED_TOTAL_ORDERS}, got {result}"
