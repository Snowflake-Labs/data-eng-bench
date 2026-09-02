"""
Tests for dbt-channel-attribution-analysis task.

This test suite validates the channel attribution analytics models including:
- Staging model: stg_orders__channels
- Intermediate model: int_customer_channel_first_touch
- Mart model: channel_performance
"""

import pytest
import subprocess
import os
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


def get_schema():
    """Get the schema name based on DB_TYPE.
    DuckDB uses main_channel_analytics (dbt concatenates default schema + custom schema).
    Snowflake uses main (generate_schema_name override forces default schema).
    """
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return "main_channel_analytics"

SCHEMA = get_schema()

# Expected counts and totals
EXPECTED_TOTAL_ORDERS = 334
EXPECTED_TOTAL_CUSTOMERS = 143
EXPECTED_TOTAL_CHANNELS = 3
EXPECTED_TOTAL_REVENUE = 125160.30

# Expected column names for the mart model in exact order
EXPECTED_COLUMNS = [
    'channel_id',
    'channel_name',
    'channel_type',
    'total_orders',
    'total_revenue',
    'unique_customers',
    'new_customers_acquired',
    'avg_order_value',
    'orders_per_customer',
    'revenue_per_customer',
    'revenue_share_pct',
    'order_share_pct',
    'customer_share_pct',
    'revenue_rank',
    'channel_efficiency',
    'acquisition_strength',
    'channel_index',
    'cross_channel_customers',
    'cross_channel_rate',
    'avg_customer_lifespan',
    'channel_engagement_score',
    'engagement_tier'
]

# Valid classification values
VALID_EFFICIENCY_VALUES = ['High Efficiency', 'Average Efficiency', 'Low Efficiency']
VALID_ACQUISITION_VALUES = ['Primary Acquisition', 'Secondary Acquisition', 'Supplementary']
VALID_ENGAGEMENT_TIERS = ['Elite', 'Strong', 'Moderate', 'Emerging']

# Spot check channels - (channel_name, total_orders, total_revenue, new_customers_acquired, revenue_rank, efficiency, acquisition, engagement_score, engagement_tier)
SPOT_CHECK_CHANNELS = [
    ('Website', 209, 77702.27, 82, 1, 'Average Efficiency', 'Primary Acquisition', 85, 'Elite'),
    ('Mobile App', 99, 39377.32, 47, 2, 'Average Efficiency', 'Secondary Acquisition', 65, 'Strong'),
    ('Marketplace', 26, 8080.71, 14, 3, 'Average Efficiency', 'Supplementary', 30, 'Emerging'),
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
        """Verify the staging model stg_orders__channels exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'stg_orders__channels'
        """)
        assert int(result) == 1, "Staging model stg_orders__channels does not exist"

    def test_intermediate_model_exists(self, db_connection):
        """Verify the intermediate model int_customer_channel_first_touch exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'int_customer_channel_first_touch'
        """)
        assert int(result) == 1, "Intermediate model int_customer_channel_first_touch does not exist"

    def test_mart_model_exists(self, db_connection):
        """Verify the mart model channel_performance exists."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'channel_performance'
        """)
        assert int(result) == 1, "Mart model channel_performance does not exist"

    def test_mart_model_is_table(self, db_connection):
        """Verify the mart model is materialized as a table, not a view."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT table_type FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'channel_performance'
        """)
        assert result is not None and 'TABLE' in str(result).upper(), f"Mart model should be a TABLE, but is {result}"


class TestColumnStructure:
    """Tests for verifying column structure and order."""

    def test_mart_column_count(self, db_connection):
        """Verify the mart model has exactly 22 columns."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'channel_performance'
        """)
        assert int(result) == 22, f"Expected 22 columns, found {result}"

    def test_mart_column_names(self, db_connection):
        """Verify all required column names exist in the mart model."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'channel_performance'
            ORDER BY ordinal_position
        """)
        actual_columns = [row[0] for row in result]
        assert actual_columns == EXPECTED_COLUMNS, f"Column mismatch. Expected: {EXPECTED_COLUMNS}, Actual: {actual_columns}"

    def test_staging_has_required_columns(self, db_connection):
        """Verify staging model has all required columns by querying data."""
        conn, db_type = db_connection
        required = ['order_id', 'customer_id', 'channel_id', 'channel_name',
                     'channel_type', 'order_date', 'order_month', 'grand_total']
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.stg_orders__channels LIMIT 0")
            actual = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute(f"SELECT * FROM {SCHEMA}.stg_orders__channels LIMIT 0")
            actual = [desc[0].lower() for desc in result.description]
        for col in required:
            assert col in actual, f"Missing column {col} in staging model. Available: {actual}"

    def test_intermediate_has_required_columns(self, db_connection):
        """Verify intermediate model has all required columns."""
        conn, db_type = db_connection
        required = ['customer_id', 'first_channel_id', 'first_channel_name',
                     'first_order_date', 'first_order_value', 'total_orders',
                     'total_spend', 'distinct_channels_used', 'is_cross_channel',
                     'customer_lifespan_days']
        result = execute_query(conn, db_type, f"""
            SELECT lower(column_name) FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'int_customer_channel_first_touch'
        """)
        actual = [row[0] for row in result]
        for col in required:
            assert col in actual, f"Missing column {col} in intermediate model"


class TestRowCounts:
    """Tests for verifying row counts."""

    def test_staging_row_count(self, db_connection):
        """Verify staging model has expected number of orders."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.stg_orders__channels
        """)
        assert int(result) == EXPECTED_TOTAL_ORDERS, f"Expected {EXPECTED_TOTAL_ORDERS} orders, found {result}"

    def test_intermediate_row_count(self, db_connection):
        """Verify intermediate model has expected number of customers."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_customer_channel_first_touch
        """)
        assert int(result) == EXPECTED_TOTAL_CUSTOMERS, f"Expected {EXPECTED_TOTAL_CUSTOMERS} customers, found {result}"

    def test_mart_row_count(self, db_connection):
        """Verify mart model has expected number of channels."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
        """)
        assert int(result) == EXPECTED_TOTAL_CHANNELS, f"Expected {EXPECTED_TOTAL_CHANNELS} channels, found {result}"


class TestDataQuality:
    """Tests for data quality and integrity."""

    def test_no_null_channel_ids(self, db_connection):
        """Verify there are no NULL channel IDs in mart model."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE channel_id IS NULL
        """)
        assert int(result) == 0, f"Found {result} rows with NULL channel_id"

    def test_no_negative_revenues(self, db_connection):
        """Verify there are no negative revenues."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE total_revenue < 0
        """)
        assert int(result) == 0, f"Found {result} rows with negative revenue"

    def test_no_negative_orders(self, db_connection):
        """Verify there are no negative order counts."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE total_orders < 0
        """)
        assert int(result) == 0, f"Found {result} rows with negative order count"

    def test_total_revenue_matches(self, db_connection):
        """Verify total revenue matches expected value."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(total_revenue), 2) FROM {SCHEMA}.channel_performance
        """)
        assert abs(float(result) - EXPECTED_TOTAL_REVENUE) < 1.0, \
            f"Expected total revenue {EXPECTED_TOTAL_REVENUE}, got {result}"

    def test_total_orders_matches(self, db_connection):
        """Verify total orders matches expected value."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(total_orders) FROM {SCHEMA}.channel_performance
        """)
        assert int(result) == EXPECTED_TOTAL_ORDERS, f"Expected {EXPECTED_TOTAL_ORDERS} total orders, got {result}"


class TestClassifications:
    """Tests for efficiency and acquisition classifications."""

    def test_valid_efficiency_values(self, db_connection):
        """Verify all channel_efficiency values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT channel_efficiency FROM {SCHEMA}.channel_performance
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_EFFICIENCY_VALUES, f"Invalid channel_efficiency: {val}"

    def test_valid_acquisition_values(self, db_connection):
        """Verify all acquisition_strength values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT acquisition_strength FROM {SCHEMA}.channel_performance
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_ACQUISITION_VALUES, f"Invalid acquisition_strength: {val}"

    def test_valid_engagement_tiers(self, db_connection):
        """Verify all engagement_tier values are valid."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT engagement_tier FROM {SCHEMA}.channel_performance
        """)
        actual_values = [row[0] for row in result]
        for val in actual_values:
            assert val in VALID_ENGAGEMENT_TIERS, f"Invalid engagement_tier: {val}"


class TestPercentages:
    """Tests for percentage calculations."""

    def test_revenue_share_sums_to_100(self, db_connection):
        """Verify revenue share percentages sum to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(revenue_share_pct) FROM {SCHEMA}.channel_performance
        """)
        assert 99.5 <= float(result) <= 100.5, \
            f"Revenue share should sum to ~100%, got {result}"

    def test_order_share_sums_to_100(self, db_connection):
        """Verify order share percentages sum to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(order_share_pct) FROM {SCHEMA}.channel_performance
        """)
        assert 99.5 <= float(result) <= 100.5, \
            f"Order share should sum to ~100%, got {result}"

    def test_customer_share_sums_to_100(self, db_connection):
        """Verify customer share percentages sum to approximately 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT SUM(customer_share_pct) FROM {SCHEMA}.channel_performance
        """)
        assert 99.5 <= float(result) <= 100.5, \
            f"Customer share should sum to ~100%, got {result}"


class TestRankings:
    """Tests for ranking columns."""

    def test_revenue_rank_starts_at_one(self, db_connection):
        """Verify revenue_rank starts at 1."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT MIN(revenue_rank) FROM {SCHEMA}.channel_performance
        """)
        assert int(result) == 1, f"Expected minimum revenue_rank to be 1, got {result}"

    def test_revenue_rank_is_integer(self, db_connection):
        """Verify revenue_rank is an integer type."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT data_type FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'channel_performance'
            AND lower(column_name) = 'revenue_rank'
        """)
        assert 'INT' in str(result).upper() or 'NUMBER' in str(result).upper(), \
            f"revenue_rank should be INTEGER, got {result}"


class TestOrdering:
    """Tests for result ordering."""

    def test_ordered_by_total_revenue_desc(self, db_connection):
        """Verify results are ordered by total_revenue descending."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT total_revenue FROM {SCHEMA}.channel_performance
        """)
        revenues = [float(row[0]) for row in result]
        assert revenues == sorted(revenues, reverse=True), \
            "Results should be ordered by total_revenue descending"

    def test_top_channel_is_rank_one(self, db_connection):
        """Verify the first row has revenue_rank = 1."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT revenue_rank FROM {SCHEMA}.channel_performance
            ORDER BY total_revenue DESC
            LIMIT 1
        """)
        assert int(result) == 1, f"First row should have revenue_rank 1, got {result}"


class TestChannelIndex:
    """Tests for channel index calculations."""

    def test_channel_index_positive(self, db_connection):
        """Verify channel_index is positive for all channels."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE channel_index <= 0
        """)
        assert int(result) == 0, f"Found {result} rows with non-positive channel_index"

    def test_channel_index_calculation(self, db_connection):
        """Verify channel_index is calculated correctly as revenue_share / order_share."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT channel_name, revenue_share_pct, order_share_pct, channel_index
            FROM {SCHEMA}.channel_performance
        """)
        for row in result:
            channel_name, rev_share, order_share, index = row
            expected_index = round(float(rev_share) / float(order_share), 2)
            assert abs(float(index) - expected_index) < 0.1, \
                f"Channel {channel_name}: expected index {expected_index}, got {index}"


class TestEngagementScore:
    """Tests for channel engagement score calculations."""

    def test_engagement_score_range(self, db_connection):
        """Verify engagement scores are within valid range (5-100)."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE channel_engagement_score < 5 OR channel_engagement_score > 100
        """)
        assert int(result) == 0, f"Found {result} rows with engagement score outside 5-100 range"

    def test_engagement_score_is_integer(self, db_connection):
        """Verify engagement_score is an integer type."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT data_type FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'channel_performance'
            AND lower(column_name) = 'channel_engagement_score'
        """)
        assert 'INT' in str(result).upper() or 'NUMBER' in str(result).upper(), \
            f"channel_engagement_score should be INTEGER, got {result}"

    def test_engagement_tier_consistency(self, db_connection):
        """Verify engagement tier matches score thresholds."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT channel_engagement_score, engagement_tier
            FROM {SCHEMA}.channel_performance
        """)
        for score, tier in result:
            score = int(score)
            if score >= 80:
                assert tier == 'Elite', f"Score {score} should be Elite, got {tier}"
            elif score >= 60:
                assert tier == 'Strong', f"Score {score} should be Strong, got {tier}"
            elif score >= 40:
                assert tier == 'Moderate', f"Score {score} should be Moderate, got {tier}"
            else:
                assert tier == 'Emerging', f"Score {score} should be Emerging, got {tier}"


class TestCrossChannelMetrics:
    """Tests for cross-channel metrics."""

    def test_cross_channel_customers_non_negative(self, db_connection):
        """Verify cross_channel_customers is non-negative."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE cross_channel_customers < 0
        """)
        assert int(result) == 0, f"Found {result} rows with negative cross_channel_customers"

    def test_cross_channel_rate_range(self, db_connection):
        """Verify cross_channel_rate is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE cross_channel_rate < 0 OR cross_channel_rate > 100
        """)
        assert int(result) == 0, f"Found {result} rows with cross_channel_rate outside 0-100"

    def test_cross_channel_rate_calculation(self, db_connection):
        """Verify cross_channel_rate is calculated correctly."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT channel_name, cross_channel_customers, new_customers_acquired, cross_channel_rate
            FROM {SCHEMA}.channel_performance
            WHERE new_customers_acquired > 0
        """)
        for row in result:
            channel, cc_customers, new_customers, cc_rate = row
            expected_rate = round(float(cc_customers) * 100.0 / float(new_customers), 2)
            assert abs(float(cc_rate) - expected_rate) < 0.5, \
                f"Channel {channel}: expected rate {expected_rate}, got {cc_rate}"

    def test_avg_customer_lifespan_non_negative(self, db_connection):
        """Verify avg_customer_lifespan is non-negative."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE avg_customer_lifespan < 0
        """)
        assert int(result) == 0, f"Found {result} rows with negative avg_customer_lifespan"


class TestSpotChecks:
    """Spot check tests for specific channels."""

    @pytest.mark.parametrize("channel_name,expected_orders,expected_revenue,expected_new_customers,expected_rank,expected_efficiency,expected_acquisition,expected_engagement_score,expected_tier", SPOT_CHECK_CHANNELS)
    def test_spot_check_channel(self, db_connection, channel_name, expected_orders, expected_revenue, expected_new_customers, expected_rank, expected_efficiency, expected_acquisition, expected_engagement_score, expected_tier):
        """Verify specific channel metrics match expected values."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT total_orders, total_revenue, new_customers_acquired,
                   revenue_rank, channel_efficiency, acquisition_strength,
                   channel_engagement_score, engagement_tier
            FROM {SCHEMA}.channel_performance
            WHERE channel_name = '{channel_name}'
        """)

        assert len(result) > 0, f"Channel {channel_name} not found"
        row = result[0]
        actual_orders, actual_revenue, actual_new_customers, actual_rank, actual_efficiency, actual_acquisition, actual_score, actual_tier = row

        assert int(actual_orders) == expected_orders, \
            f"Channel {channel_name}: expected orders {expected_orders}, got {actual_orders}"
        assert abs(float(actual_revenue) - expected_revenue) < 0.1, \
            f"Channel {channel_name}: expected revenue {expected_revenue}, got {actual_revenue}"
        assert int(actual_new_customers) == expected_new_customers, \
            f"Channel {channel_name}: expected new customers {expected_new_customers}, got {actual_new_customers}"
        assert int(actual_rank) == expected_rank, \
            f"Channel {channel_name}: expected rank {expected_rank}, got {actual_rank}"
        assert actual_efficiency == expected_efficiency, \
            f"Channel {channel_name}: expected efficiency '{expected_efficiency}', got '{actual_efficiency}'"
        assert actual_acquisition == expected_acquisition, \
            f"Channel {channel_name}: expected acquisition '{expected_acquisition}', got '{actual_acquisition}'"
        assert abs(int(actual_score) - expected_engagement_score) <= 5, \
            f"Channel {channel_name}: expected engagement score ~{expected_engagement_score}, got {actual_score}"
        assert actual_tier == expected_tier, \
            f"Channel {channel_name}: expected tier '{expected_tier}', got '{actual_tier}'"


class TestDateFiltering:
    """Tests for date filtering in staging model."""

    def test_all_orders_in_2024(self, db_connection):
        """Verify all orders in staging are from 2024."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.stg_orders__channels
            WHERE order_date < '2024-01-01' OR order_date >= '2025-01-01'
        """)
        assert int(result) == 0, f"Found {result} orders outside 2024"

    def test_order_date_is_date_type(self, db_connection):
        """Verify order_date is DATE type, not TIMESTAMP."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT data_type FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'stg_orders__channels'
            AND lower(column_name) = 'order_date'
        """)
        assert 'DATE' in str(result).upper(), f"order_date should be DATE type, got {result}"


class TestFirstTouchAttribution:
    """Tests for first-touch attribution logic."""

    def test_each_customer_has_one_first_touch(self, db_connection):
        """Verify each customer appears exactly once in the intermediate model."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT customer_id, COUNT(*) as cnt
            FROM {SCHEMA}.int_customer_channel_first_touch
            GROUP BY customer_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Found customers with multiple first-touch records: {result}"

    def test_total_new_customers_equals_intermediate_count(self, db_connection):
        """Verify sum of new_customers_acquired equals intermediate model count."""
        conn, db_type = db_connection
        new_customers_sum = execute_scalar(conn, db_type, f"""
            SELECT SUM(new_customers_acquired) FROM {SCHEMA}.channel_performance
        """)
        intermediate_count = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_customer_channel_first_touch
        """)
        assert int(new_customers_sum) == int(intermediate_count), \
            f"Sum of new_customers_acquired ({new_customers_sum}) should equal intermediate count ({intermediate_count})"

    def test_is_cross_channel_values(self, db_connection):
        """Verify is_cross_channel only contains Y or N."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT is_cross_channel
            FROM {SCHEMA}.int_customer_channel_first_touch
        """)
        values = [row[0] for row in result]
        for val in values:
            assert val in ['Y', 'N'], f"Invalid is_cross_channel value: {val}"


class TestMetricConsistency:
    """Tests for metric consistency and calculations."""

    def test_avg_order_value_calculation(self, db_connection):
        """Verify avg_order_value is calculated correctly."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT channel_name, total_revenue, total_orders, avg_order_value
            FROM {SCHEMA}.channel_performance
        """)
        for row in result:
            channel_name, revenue, orders, aov = row
            expected_aov = round(float(revenue) / int(orders), 2)
            assert abs(float(aov) - expected_aov) < 0.1, \
                f"Channel {channel_name}: expected AOV {expected_aov}, got {aov}"

    def test_orders_per_customer_calculation(self, db_connection):
        """Verify orders_per_customer is calculated correctly."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT channel_name, total_orders, unique_customers, orders_per_customer
            FROM {SCHEMA}.channel_performance
        """)
        for row in result:
            channel_name, orders, customers, opc = row
            expected_opc = round(int(orders) / int(customers), 2)
            assert abs(float(opc) - expected_opc) < 0.1, \
                f"Channel {channel_name}: expected orders per customer {expected_opc}, got {opc}"


class TestIdempotency:
    """Tests for idempotency and determinism."""

    def test_unique_channel_ids(self, db_connection):
        """Verify all channel IDs are unique in mart model."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) - COUNT(DISTINCT channel_id)
            FROM {SCHEMA}.channel_performance
        """)
        assert int(result) == 0, f"Found {result} duplicate channel IDs"

    def test_unique_channel_names(self, db_connection):
        """Verify all channel names are unique in mart model."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) - COUNT(DISTINCT channel_name)
            FROM {SCHEMA}.channel_performance
        """)
        assert int(result) == 0, f"Found {result} duplicate channel names"


class TestChannelTypes:
    """Tests for channel type validation."""

    def test_all_channels_have_type(self, db_connection):
        """Verify all channels have a channel_type."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.channel_performance
            WHERE channel_type IS NULL OR channel_type = ''
        """)
        assert int(result) == 0, f"Found {result} channels without a type"

    def test_channel_type_in_staging(self, db_connection):
        """Verify channel_type exists in staging model."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT channel_type FROM {SCHEMA}.stg_orders__channels
        """)
        types = [row[0] for row in result]
        assert len(types) > 0, "No channel types found in staging"
        assert 'DIGITAL' in types, "Expected DIGITAL channel type in staging"
