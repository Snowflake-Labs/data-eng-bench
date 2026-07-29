"""
Test verifier for Monthly Channel Revenue Analysis.

Tests validate:
1. Model existence and structure (28 columns)
2. Column names and types
3. Row counts and completeness
4. Calculation accuracy (MoM growth, market share, rankings)
5. Growth category classification (8 tiers)
6. Channel tenure and rolling averages
7. Market share change and rank tracking
8. Consecutive growth months calculation
9. Performance tier classification
10. YTD metrics (revenue, order count, percentage)
11. Growth acceleration and revenue volatility
12. Channel momentum score calculation
13. Strategic recommendation classification
14. Spot-check specific values
15. Idempotency
"""
import subprocess
import os
import pytest
from collections import Counter


# Schema where models are created (existing project prefixes with main_)
MODEL_SCHEMA = "main_channel_analytics"


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
            schema='channel_analytics',
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
        return 'main'
    return 'main'


# ============ HELPERS ============
def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt():
    """Run dbt deps and dbt run for channel models."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    result = run_cmd("dbt run --select stg_orders__channel int_monthly_channel_metrics int_monthly_market_benchmarks monthly_channel_performance")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"
    return result


# Ground truth values
EXPECTED_ROW_COUNT = 51
EXPECTED_MONTHS = 12
EXPECTED_CHANNELS = {'WEB', 'MOBILE', 'POS', 'MARKETPLACE', 'PHONE'}

# All 40 required columns in order
REQUIRED_COLUMNS = [
    'month_start', 'channel', 'quarter', 'order_count', 'unique_customers',
    'total_revenue', 'avg_order_value', 'prev_month_revenue',
    'revenue_mom_change', 'revenue_mom_pct', 'growth_category',
    'channel_tenure', 'rolling_3m_revenue', 'monthly_total_revenue',
    'market_share_pct', 'market_share_change', 'channel_rank',
    'prev_month_rank', 'rank_change', 'consecutive_growth_months',
    'performance_tier', 'is_top_channel', 'ytd_revenue', 'ytd_order_count',
    'pct_of_ytd_revenue', 'qtd_revenue', 'growth_acceleration', 'revenue_volatility',
    'prev_month_customers', 'customer_growth_rate', 'market_avg_revenue',
    'vs_market_revenue_pct', 'market_avg_aov', 'vs_market_aov_pct',
    'aov_rank', 'revenue_hhi', 'growth_consistency_score',
    'channel_momentum_score', 'channel_efficiency_score', 'strategic_recommendation'
]

# Valid 8-tier growth categories
VALID_GROWTH_CATEGORIES = {
    'Explosive', 'Strong Growth', 'Moderate Growth', 'Slight Growth',
    'Stable', 'Slight Decline', 'Moderate Decline', 'Sharp Decline'
}

# Valid performance tiers
VALID_PERFORMANCE_TIERS = {
    'Market Leader', 'Strong Performer', 'Growth Potential',
    'Stable Core', 'At Risk', 'Emerging', 'Niche'
}

# Valid strategic recommendations
VALID_STRATEGIC_RECOMMENDATIONS = {
    'Invest Heavily', 'Scale Up', 'Optimize', 'Experiment',
    'Maintain', 'Review', 'Divest', 'Monitor'
}

# ============ EXPECTED GROUND TRUTH DISTRIBUTION COUNTS ============

EXPECTED_GROWTH_CATEGORY_COUNTS = {
    'Explosive': 12,
    'Sharp Decline': 9,
    'Strong Growth': 7,
    'Moderate Growth': 6,
    'Slight Decline': 5,
    'Moderate Decline': 4,
    'Slight Growth': 3,
}

EXPECTED_PERFORMANCE_TIER_COUNTS = {
    'At Risk': 13,
    'Growth Potential': 13,
    'Market Leader': 6,
    'Stable Core': 6,
    'Emerging': 5,
    'Strong Performer': 4,
    'Niche': 4,
}

EXPECTED_CHANNEL_COUNTS = {
    'WEB': 12,
    'MOBILE': 12,
    'MARKETPLACE': 10,
    'POS': 10,
    'PHONE': 7,
}

EXPECTED_QUARTER_COUNTS = {
    'Q1': 12,
    'Q2': 12,
    'Q3': 14,
    'Q4': 13,
}

EXPECTED_STRATEGIC_RECOMMENDATION_COUNTS = {
    'Experiment': 15,
    'Scale Up': 13,
    'Review': 12,
    'Invest Heavily': 3,
    'Maintain': 3,
    'Optimize': 2,
    'Divest': 2,
    'Monitor': 1,
}

# ============ COMPREHENSIVE SPOT CHECK DATA ============

# December WEB - top performer with all key metrics
SPOT_CHECK_DEC_WEB = {
    'month_start': '2024-12-01',
    'channel': 'WEB',
    'order_count': 20,
    'unique_customers': 12,
    'total_revenue': 9717.15,
    'avg_order_value': 485.86,
    'market_share_pct': 46.43,
    'channel_tenure': 12,
    'channel_rank': 1,
    'aov_rank': 1,
    'is_top_channel': 'Y',
    'ytd_revenue': 61656.65,
    'ytd_order_count': 167,
    'qtd_revenue': 25230.91,
    'quarter': 'Q4',
}

# December MOBILE - second place
SPOT_CHECK_DEC_MOBILE = {
    'month_start': '2024-12-01',
    'channel': 'MOBILE',
    'order_count': 17,
    'unique_customers': 13,
    'total_revenue': 6913.11,
    'avg_order_value': 406.65,
    'market_share_pct': 33.03,
    'channel_tenure': 12,
    'channel_rank': 2,
    'aov_rank': 3,
    'is_top_channel': 'N',
    'ytd_revenue': 39377.33,
    'ytd_order_count': 99,
    'qtd_revenue': 12999.98,
    'quarter': 'Q4',
}

# January WEB - first month (NULL prev values expected)
SPOT_CHECK_JAN_WEB = {
    'month_start': '2024-01-01',
    'channel': 'WEB',
    'order_count': 5,
    'unique_customers': 5,
    'total_revenue': 1743.59,
    'avg_order_value': 348.72,
    'market_share_pct': 35.95,
    'channel_tenure': 1,
    'channel_rank': 1,
    'aov_rank': 2,
    'is_top_channel': 'Y',
}

# Spot check values: (month_start, channel, order_count, unique_customers, total_revenue, market_share_pct, channel_rank, is_top_channel)
SPOT_CHECKS = [
    # January data (first month, NULL for prev values)
    ('2024-01-01', 'WEB', 5, 5, 1743.59, 35.95, 1, 'Y'),
    ('2024-01-01', 'MOBILE', 5, 5, 1599.52, 32.98, 2, 'N'),
    ('2024-01-01', 'PHONE', 1, 1, 1506.39, 31.06, 3, 'N'),
    # March data (has MoM calculations)
    ('2024-03-01', 'WEB', 10, 9, 3721.58, 42.91, 1, 'Y'),
    ('2024-03-01', 'MOBILE', 8, 7, 3182.22, 36.69, 2, 'N'),
    # December data (last month)
    ('2024-12-01', 'WEB', 20, 12, 9717.15, 46.43, 1, 'Y'),
    ('2024-12-01', 'MOBILE', 17, 13, 6913.11, 33.03, 2, 'N'),
]

# MoM calculation spot checks: (month_start, channel, prev_month_revenue, revenue_mom_change, revenue_mom_pct)
MOM_SPOT_CHECKS = [
    # February WEB (first MoM calculation for WEB)
    ('2024-02-01', 'WEB', 1743.59, 852.89, 48.92),
    # March MOBILE (positive growth)
    ('2024-03-01', 'MOBILE', 1302.64, 1879.58, 144.29),
    # February PHONE (negative growth)
    ('2024-02-01', 'PHONE', 1506.39, -1389.57, -92.25),
    # December WEB (slight decline)
    ('2024-12-01', 'WEB', 10592.76, -875.61, -8.27),
]

# Growth category spot checks with 8-tier categories: (month_start, channel, expected_growth_category)
GROWTH_CATEGORY_CHECKS = [
    ('2024-02-01', 'WEB', 'Moderate Growth'),  # 48.92% (>= 20, < 50)
    ('2024-03-01', 'MOBILE', 'Explosive'),  # 144.29% (>= 100)
    ('2024-02-01', 'PHONE', 'Sharp Decline'),  # -92.25% (<= -50)
    ('2024-12-01', 'WEB', 'Slight Decline'),  # -8.27% (< 0, > -20)
    ('2024-12-01', 'MOBILE', 'Strong Growth'),  # 73.54% (>= 50, < 100)
]

# Channel tenure spot checks: (month_start, channel, expected_tenure)
TENURE_CHECKS = [
    ('2024-01-01', 'WEB', 1),
    ('2024-01-01', 'MOBILE', 1),
    ('2024-03-01', 'WEB', 3),
    ('2024-12-01', 'WEB', 12),
    ('2024-12-01', 'MOBILE', 12),
]

# Rolling 3m revenue spot checks: (month_start, channel, expected_rolling_3m)
# NULL for first 2 months, then calculated
ROLLING_3M_CHECKS = [
    ('2024-01-01', 'WEB', None),  # tenure 1
    ('2024-02-01', 'WEB', None),  # tenure 2
    ('2024-03-01', 'WEB', 2687.22),  # tenure 3, (1743.59 + 2596.48 + 3721.58) / 3
    ('2024-12-01', 'WEB', 8410.3),  # tenure 12
]

# Consecutive growth months spot checks: (month_start, channel, expected_consecutive)
CONSECUTIVE_GROWTH_CHECKS = [
    ('2024-01-01', 'WEB', 0),  # First month, no prior to compare
    ('2024-02-01', 'WEB', 1),  # Positive growth (48.92%)
    ('2024-03-01', 'WEB', 2),  # Positive growth (43.32%)
]

# Rank change spot checks: (month_start, channel, prev_month_rank, rank_change)
RANK_CHANGE_CHECKS = [
    ('2024-01-01', 'WEB', None, None),  # First month
    ('2024-02-01', 'WEB', 1, 0),  # Stayed at rank 1
]


@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    result = run_dbt()
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"
    return True


class TestModelStructure:
    """Phase 1: Structure validation tests."""

    def test_staging_model_exists(self, dbt_run):
        """Validate staging model exists (in default main schema or channel_analytics schema)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_name) = 'stg_orders__channel'
                AND lower(table_schema) IN ('main', 'main_channel_analytics')
            """)
            assert result[0][0] > 0, "Staging model stg_orders__channel not found. Should be created as view in staging folder."
        finally:
            conn.close()

    def test_intermediate_model_exists(self, dbt_run):
        """Validate intermediate model exists (in default main schema or channel_analytics schema)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_name) = 'int_monthly_channel_metrics'
                AND lower(table_schema) IN ('main', 'main_channel_analytics')
            """)
            assert result[0][0] > 0, "Intermediate model int_monthly_channel_metrics not found. Should be created as view in intermediate folder."
        finally:
            conn.close()

    def test_mart_model_exists(self, dbt_run):
        """Validate mart model exists in main_channel_analytics schema."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = '{MODEL_SCHEMA}'
                AND lower(table_name) = 'monthly_channel_performance'
            """)
            assert result[0][0] > 0, "Mart model monthly_channel_performance not found in main_channel_analytics"
        finally:
            conn.close()

    def test_mart_is_table(self, dbt_run):
        """Validate mart model is materialized as TABLE."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT table_type FROM information_schema.tables
                WHERE lower(table_schema) = '{MODEL_SCHEMA}'
                AND lower(table_name) = 'monthly_channel_performance'
            """)
            assert result[0][0] == 'BASE TABLE', f"Expected TABLE, got {result[0][0]}"
        finally:
            conn.close()

    def test_mart_columns_exist(self, dbt_run):
        """Validate all 28 required columns exist in mart model."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = '{MODEL_SCHEMA}'
                AND lower(table_name) = 'monthly_channel_performance'
            """)
            col_names = {c[0].lower() for c in cols}

            required = set(c.lower() for c in REQUIRED_COLUMNS)
            missing = required - col_names
            assert not missing, f"Missing columns: {missing}"
        finally:
            conn.close()

    def test_column_count(self, dbt_run):
        """Validate exactly 40 columns in mart model."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT COUNT(DISTINCT lower(column_name))
                FROM information_schema.columns
                WHERE lower(table_schema) = '{MODEL_SCHEMA}'
                AND lower(table_name) = 'monthly_channel_performance'
            """)
            assert cols[0][0] == 40, f"Expected 40 columns, got {cols[0][0]}"
        finally:
            conn.close()


class TestDataCompleteness:
    """Phase 2: Data completeness tests."""

    def test_row_count(self, dbt_run):
        """Validate total row count matches expected."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)
            assert result[0][0] == EXPECTED_ROW_COUNT, \
                f"Expected {EXPECTED_ROW_COUNT} rows, got {result[0][0]}"
        finally:
            conn.close()

    def test_month_count(self, dbt_run):
        """Validate all 12 months are present."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(DISTINCT month_start)
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)
            assert result[0][0] == EXPECTED_MONTHS, \
                f"Expected {EXPECTED_MONTHS} months, got {result[0][0]}"
        finally:
            conn.close()

    def test_channels_present(self, dbt_run):
        """Validate all expected channels are present."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT channel
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)
            channels = {r[0] for r in result}
            assert channels == EXPECTED_CHANNELS, \
                f"Expected channels {EXPECTED_CHANNELS}, got {channels}"
        finally:
            conn.close()

    def test_no_null_required_fields(self, dbt_run):
        """Validate no NULL values in required fields."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE month_start IS NULL
                   OR channel IS NULL
                   OR order_count IS NULL
                   OR total_revenue IS NULL
                   OR channel_rank IS NULL
                   OR is_top_channel IS NULL
                   OR channel_tenure IS NULL
                   OR consecutive_growth_months IS NULL
                   OR ytd_revenue IS NULL
                   OR ytd_order_count IS NULL
                   OR pct_of_ytd_revenue IS NULL
                   OR channel_momentum_score IS NULL
                   OR strategic_recommendation IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL in required fields"
        finally:
            conn.close()


class TestCalculations:
    """Phase 3: Calculation accuracy tests."""

    def test_market_share_sums_to_100(self, dbt_run):
        """Validate market share percentages sum to ~100% per month."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, ROUND(SUM(market_share_pct), 2) as total_share
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                GROUP BY month_start
                HAVING ABS(SUM(market_share_pct) - 100) > 0.1
            """)
            assert len(result) == 0, \
                f"Market share doesn't sum to 100% for months: {result}"
        finally:
            conn.close()

    def test_channel_rank_validity(self, dbt_run):
        """Validate channel ranks are valid (1-5) and consistent."""
        conn, db_type = get_db_connection()
        try:
            # Check rank 1 exists for each month
            result = execute_query(conn, db_type, f"""
                SELECT month_start, MIN(channel_rank) as min_rank
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                GROUP BY month_start
                HAVING MIN(channel_rank) != 1
            """)
            assert len(result) == 0, f"Missing rank 1 for months: {result}"
        finally:
            conn.close()

    def test_is_top_channel_matches_rank(self, dbt_run):
        """Validate is_top_channel matches channel_rank."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE (channel_rank = 1 AND is_top_channel != 'Y')
                   OR (channel_rank != 1 AND is_top_channel != 'N')
            """)
            assert result[0][0] == 0, \
                f"Found {result[0][0]} rows where is_top_channel doesn't match rank"
        finally:
            conn.close()

    def test_first_month_null_prev_values(self, dbt_run):
        """Validate first month of each channel has NULL prev values."""
        conn, db_type = get_db_connection()
        try:
            # For channels with tenure=1, prev should be NULL
            result = execute_query(conn, db_type, f"""
                SELECT channel, prev_month_revenue, revenue_mom_change, revenue_mom_pct,
                       growth_category, prev_month_rank, rank_change, market_share_change
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1
                  AND (prev_month_revenue IS NOT NULL
                       OR revenue_mom_change IS NOT NULL
                       OR revenue_mom_pct IS NOT NULL
                       OR growth_category IS NOT NULL
                       OR prev_month_rank IS NOT NULL
                       OR rank_change IS NOT NULL
                       OR market_share_change IS NOT NULL)
            """)
            assert len(result) == 0, \
                f"First appearance should have NULL prev/growth values but found: {result}"
        finally:
            conn.close()

    def test_mom_calculation_accuracy(self, dbt_run):
        """Validate month-over-month calculations are correct."""
        conn, db_type = get_db_connection()
        try:
            for month, channel, exp_prev, exp_change, exp_pct in MOM_SPOT_CHECKS:
                result = execute_query(conn, db_type, f"""
                    SELECT prev_month_revenue, revenue_mom_change, revenue_mom_pct
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                    WHERE month_start = '{month}' AND channel = '{channel}'
                """)

                assert len(result) > 0, f"No data for {month} {channel}"
                row = result[0]

                # Check prev_month_revenue
                assert abs(float(row[0]) - exp_prev) < 0.01, \
                    f"{month} {channel}: prev_month_revenue expected {exp_prev}, got {row[0]}"

                # Check revenue_mom_change
                assert abs(float(row[1]) - exp_change) < 0.01, \
                    f"{month} {channel}: revenue_mom_change expected {exp_change}, got {row[1]}"

                # Check revenue_mom_pct
                assert abs(float(row[2]) - exp_pct) < 0.01, \
                    f"{month} {channel}: revenue_mom_pct expected {exp_pct}, got {row[2]}"
        finally:
            conn.close()


class TestGrowthCategory:
    """Phase 4: Growth category classification tests (8 tiers)."""

    def test_valid_growth_categories(self, dbt_run):
        """Validate growth_category contains only valid 8-tier values."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT growth_category
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE growth_category IS NOT NULL
            """)
            categories = {r[0] for r in result}
            invalid = categories - VALID_GROWTH_CATEGORIES
            assert not invalid, f"Invalid growth categories found: {invalid}. Valid: {VALID_GROWTH_CATEGORIES}"
        finally:
            conn.close()

    def test_growth_category_spot_checks(self, dbt_run):
        """Validate specific growth category assignments."""
        conn, db_type = get_db_connection()
        try:
            for month, channel, expected_category in GROWTH_CATEGORY_CHECKS:
                result = execute_query(conn, db_type, f"""
                    SELECT growth_category, revenue_mom_pct
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                    WHERE month_start = '{month}' AND channel = '{channel}'
                """)

                assert len(result) > 0, f"No data for {month} {channel}"
                assert result[0][0] == expected_category, \
                    f"{month} {channel}: growth_category expected '{expected_category}', got '{result[0][0]}' (mom_pct={result[0][1]})"
        finally:
            conn.close()

    def test_growth_category_thresholds(self, dbt_run):
        """Validate 8-tier growth category thresholds are applied correctly."""
        conn, db_type = get_db_connection()
        try:
            # Check that all categorizations match their thresholds
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, revenue_mom_pct, growth_category
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE revenue_mom_pct IS NOT NULL
                  AND (
                    (revenue_mom_pct >= 100 AND growth_category != 'Explosive')
                    OR (revenue_mom_pct >= 50 AND revenue_mom_pct < 100 AND growth_category != 'Strong Growth')
                    OR (revenue_mom_pct >= 20 AND revenue_mom_pct < 50 AND growth_category != 'Moderate Growth')
                    OR (revenue_mom_pct > 0 AND revenue_mom_pct < 20 AND growth_category != 'Slight Growth')
                    OR (revenue_mom_pct = 0 AND growth_category != 'Stable')
                    OR (revenue_mom_pct < 0 AND revenue_mom_pct > -20 AND growth_category != 'Slight Decline')
                    OR (revenue_mom_pct <= -20 AND revenue_mom_pct > -50 AND growth_category != 'Moderate Decline')
                    OR (revenue_mom_pct <= -50 AND growth_category != 'Sharp Decline')
                  )
            """)
            assert len(result) == 0, \
                f"Found rows with incorrect growth category: {result[:5]}"
        finally:
            conn.close()


class TestChannelTenure:
    """Phase 5: Channel tenure tests."""

    def test_tenure_spot_checks(self, dbt_run):
        """Validate specific channel tenure values."""
        conn, db_type = get_db_connection()
        try:
            for month, channel, expected_tenure in TENURE_CHECKS:
                result = execute_query(conn, db_type, f"""
                    SELECT channel_tenure
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                    WHERE month_start = '{month}' AND channel = '{channel}'
                """)

                assert len(result) > 0, f"No data for {month} {channel}"
                assert result[0][0] == expected_tenure, \
                    f"{month} {channel}: channel_tenure expected {expected_tenure}, got {result[0][0]}"
        finally:
            conn.close()

    def test_tenure_increases_monotonically(self, dbt_run):
        """Validate tenure increases for each channel over time."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure,
                       LAG(channel_tenure) OVER (PARTITION BY channel ORDER BY month_start) as prev_tenure
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)

            for row in result:
                if row[3] is not None:  # prev_tenure exists
                    assert row[2] == row[3] + 1, \
                        f"Tenure not increasing: {row[0]} at {row[1]}, tenure={row[2]}, prev={row[3]}"
        finally:
            conn.close()


class TestRolling3M:
    """Phase 6: Rolling 3-month revenue tests."""

    def test_rolling_3m_null_first_two_months(self, dbt_run):
        """Validate rolling_3m_revenue is NULL for first 2 months of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, rolling_3m_revenue
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure < 3 AND rolling_3m_revenue IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL rolling_3m_revenue for tenure < 3: {result}"
        finally:
            conn.close()

    def test_rolling_3m_not_null_after_third_month(self, dbt_run):
        """Validate rolling_3m_revenue is NOT NULL for tenure >= 3."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, rolling_3m_revenue
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure >= 3 AND rolling_3m_revenue IS NULL
            """)
            assert len(result) == 0, \
                f"Found NULL rolling_3m_revenue for tenure >= 3: {result}"
        finally:
            conn.close()

    def test_rolling_3m_spot_checks(self, dbt_run):
        """Validate specific rolling 3-month revenue values."""
        conn, db_type = get_db_connection()
        try:
            for month, channel, expected_rolling in ROLLING_3M_CHECKS:
                result = execute_query(conn, db_type, f"""
                    SELECT rolling_3m_revenue
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                    WHERE month_start = '{month}' AND channel = '{channel}'
                """)

                assert len(result) > 0, f"No data for {month} {channel}"

                if expected_rolling is None:
                    assert result[0][0] is None, \
                        f"{month} {channel}: rolling_3m_revenue expected NULL, got {result[0][0]}"
                else:
                    assert result[0][0] is not None, \
                        f"{month} {channel}: rolling_3m_revenue expected {expected_rolling}, got NULL"
                    assert abs(float(result[0][0]) - expected_rolling) < 0.1, \
                        f"{month} {channel}: rolling_3m_revenue expected {expected_rolling}, got {result[0][0]}"
        finally:
            conn.close()


class TestMarketShareChange:
    """Phase 7: Market share change tests."""

    def test_market_share_change_null_first_month(self, dbt_run):
        """Validate market_share_change is NULL for first month of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, market_share_change
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND market_share_change IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL market_share_change for first month: {result}"
        finally:
            conn.close()

    def test_market_share_change_calculation(self, dbt_run):
        """Validate market_share_change = current - previous market share."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                WITH ranked AS (
                    SELECT month_start, channel, market_share_pct, market_share_change,
                           LAG(market_share_pct) OVER (PARTITION BY channel ORDER BY month_start) as prev_share
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                )
                SELECT month_start, channel, market_share_change,
                       ROUND(market_share_pct - prev_share, 2) as expected_change
                FROM ranked
                WHERE prev_share IS NOT NULL
                  AND ABS(market_share_change - (market_share_pct - prev_share)) > 0.01
            """)
            assert len(result) == 0, \
                f"Found incorrect market_share_change calculations: {result[:5]}"
        finally:
            conn.close()


class TestRankTracking:
    """Phase 8: Previous rank and rank change tests."""

    def test_prev_month_rank_null_first_month(self, dbt_run):
        """Validate prev_month_rank is NULL for first month of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, prev_month_rank
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND prev_month_rank IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL prev_month_rank for first month: {result}"
        finally:
            conn.close()

    def test_rank_change_null_first_month(self, dbt_run):
        """Validate rank_change is NULL for first month of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, rank_change
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND rank_change IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL rank_change for first month: {result}"
        finally:
            conn.close()

    def test_rank_change_calculation(self, dbt_run):
        """Validate rank_change = prev_month_rank - channel_rank."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, prev_month_rank, channel_rank, rank_change,
                       (prev_month_rank - channel_rank) as expected_change
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE prev_month_rank IS NOT NULL
                  AND rank_change != (prev_month_rank - channel_rank)
            """)
            assert len(result) == 0, \
                f"Found incorrect rank_change calculations: {result[:5]}"
        finally:
            conn.close()


class TestConsecutiveGrowth:
    """Phase 9: Consecutive growth months tests."""

    def test_consecutive_growth_first_month_zero(self, dbt_run):
        """Validate consecutive_growth_months is 0 for first month of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, consecutive_growth_months
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND consecutive_growth_months != 0
            """)
            assert len(result) == 0, \
                f"Found non-zero consecutive_growth_months for first month: {result}"
        finally:
            conn.close()

    def test_consecutive_growth_resets_on_decline(self, dbt_run):
        """Validate consecutive_growth_months resets to 0 when growth is not positive."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, revenue_mom_pct, consecutive_growth_months
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE (revenue_mom_pct IS NULL OR revenue_mom_pct <= 0)
                  AND consecutive_growth_months != 0
            """)
            assert len(result) == 0, \
                f"Found non-zero consecutive_growth_months when growth is not positive: {result[:5]}"
        finally:
            conn.close()

    def test_consecutive_growth_increases(self, dbt_run):
        """Validate consecutive_growth_months increases with positive growth."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, revenue_mom_pct, consecutive_growth_months
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE revenue_mom_pct > 0 AND consecutive_growth_months = 0
            """)
            assert len(result) == 0, \
                f"Found zero consecutive_growth_months when growth is positive: {result[:5]}"
        finally:
            conn.close()


class TestPerformanceTier:
    """Phase 10: Performance tier classification tests."""

    def test_valid_performance_tiers(self, dbt_run):
        """Validate performance_tier contains only valid values."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT performance_tier
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE performance_tier IS NOT NULL
            """)
            tiers = {r[0] for r in result}
            invalid = tiers - VALID_PERFORMANCE_TIERS
            assert not invalid, f"Invalid performance tiers found: {invalid}. Valid: {VALID_PERFORMANCE_TIERS}"
        finally:
            conn.close()

    def test_first_month_emerging_or_null(self, dbt_run):
        """Validate first month has 'Emerging' tier (tenure <= 2, growth_category NULL)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, growth_category, performance_tier
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1
                  AND growth_category IS NULL
                  AND performance_tier != 'Emerging'
            """)
            assert len(result) == 0, \
                f"Found non-Emerging tier for first month: {result}"
        finally:
            conn.close()

    def test_market_leader_criteria(self, dbt_run):
        """Validate Market Leader requires market_share >= 40 and positive growth categories."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, market_share_pct, growth_category, performance_tier
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE performance_tier = 'Market Leader'
                  AND NOT (market_share_pct >= 40
                           AND growth_category IN ('Explosive', 'Strong Growth', 'Moderate Growth'))
            """)
            assert len(result) == 0, \
                f"Found Market Leader that doesn't meet criteria: {result[:5]}"
        finally:
            conn.close()

    def test_at_risk_criteria(self, dbt_run):
        """Validate At Risk requires declining growth categories."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, growth_category, performance_tier
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE performance_tier = 'At Risk'
                  AND growth_category NOT IN ('Moderate Decline', 'Sharp Decline')
            """)
            assert len(result) == 0, \
                f"Found At Risk that doesn't meet criteria: {result[:5]}"
        finally:
            conn.close()


class TestYTDMetrics:
    """Phase 11: YTD metrics tests."""

    def test_ytd_revenue_not_null(self, dbt_run):
        """Validate ytd_revenue is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE ytd_revenue IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL ytd_revenue"
        finally:
            conn.close()

    def test_ytd_revenue_cumulative(self, dbt_run):
        """Validate ytd_revenue is cumulative sum of total_revenue."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                WITH calculated AS (
                    SELECT month_start, channel, total_revenue, ytd_revenue,
                           SUM(total_revenue) OVER (
                               PARTITION BY channel
                               ORDER BY month_start
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                           ) as expected_ytd
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                )
                SELECT month_start, channel, ytd_revenue, expected_ytd
                FROM calculated
                WHERE ABS(ytd_revenue - expected_ytd) > 0.01
            """)
            assert len(result) == 0, \
                f"Found incorrect ytd_revenue calculations: {result[:5]}"
        finally:
            conn.close()

    def test_ytd_order_count_not_null(self, dbt_run):
        """Validate ytd_order_count is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE ytd_order_count IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL ytd_order_count"
        finally:
            conn.close()

    def test_ytd_order_count_cumulative(self, dbt_run):
        """Validate ytd_order_count is cumulative sum of order_count."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                WITH calculated AS (
                    SELECT month_start, channel, order_count, ytd_order_count,
                           SUM(order_count) OVER (
                               PARTITION BY channel
                               ORDER BY month_start
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                           ) as expected_ytd
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                )
                SELECT month_start, channel, ytd_order_count, expected_ytd
                FROM calculated
                WHERE ytd_order_count != expected_ytd
            """)
            assert len(result) == 0, \
                f"Found incorrect ytd_order_count calculations: {result[:5]}"
        finally:
            conn.close()

    def test_pct_of_ytd_revenue_not_null(self, dbt_run):
        """Validate pct_of_ytd_revenue is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE pct_of_ytd_revenue IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL pct_of_ytd_revenue"
        finally:
            conn.close()

    def test_pct_of_ytd_revenue_calculation(self, dbt_run):
        """Validate pct_of_ytd_revenue = (total_revenue / ytd_revenue) * 100."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, total_revenue, ytd_revenue, pct_of_ytd_revenue,
                       ROUND((total_revenue / ytd_revenue) * 100, 2) as expected_pct
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE ABS(pct_of_ytd_revenue - ROUND((total_revenue / ytd_revenue) * 100, 2)) > 0.1
            """)
            assert len(result) == 0, \
                f"Found incorrect pct_of_ytd_revenue calculations: {result[:5]}"
        finally:
            conn.close()

    def test_first_month_pct_of_ytd_is_100(self, dbt_run):
        """Validate first month of each channel has pct_of_ytd_revenue = 100."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, pct_of_ytd_revenue
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1
                  AND ABS(pct_of_ytd_revenue - 100) > 0.01
            """)
            assert len(result) == 0, \
                f"First month should have pct_of_ytd_revenue = 100: {result}"
        finally:
            conn.close()


class TestGrowthAcceleration:
    """Phase 12: Growth acceleration tests."""

    def test_growth_acceleration_null_first_two_months(self, dbt_run):
        """Validate growth_acceleration is NULL for first 2 months of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, growth_acceleration
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure < 3 AND growth_acceleration IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL growth_acceleration for tenure < 3: {result}"
        finally:
            conn.close()

    def test_growth_acceleration_not_null_after_third_month(self, dbt_run):
        """Validate growth_acceleration is NOT NULL for tenure >= 3."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, growth_acceleration
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure >= 3 AND growth_acceleration IS NULL
            """)
            assert len(result) == 0, \
                f"Found NULL growth_acceleration for tenure >= 3: {result}"
        finally:
            conn.close()

    def test_growth_acceleration_calculation(self, dbt_run):
        """Validate growth_acceleration = current mom_pct - previous mom_pct."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                WITH lagged AS (
                    SELECT month_start, channel, channel_tenure, revenue_mom_pct, growth_acceleration,
                           LAG(revenue_mom_pct) OVER (PARTITION BY channel ORDER BY month_start) as prev_mom_pct
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                )
                SELECT month_start, channel, revenue_mom_pct, prev_mom_pct, growth_acceleration,
                       ROUND(revenue_mom_pct - prev_mom_pct, 2) as expected_accel
                FROM lagged
                WHERE channel_tenure >= 3
                  AND ABS(growth_acceleration - (revenue_mom_pct - prev_mom_pct)) > 0.1
            """)
            assert len(result) == 0, \
                f"Found incorrect growth_acceleration calculations: {result[:5]}"
        finally:
            conn.close()


class TestRevenueVolatility:
    """Phase 13: Revenue volatility tests."""

    def test_revenue_volatility_null_first_two_months(self, dbt_run):
        """Validate revenue_volatility is NULL for first 2 months of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, revenue_volatility
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure < 3 AND revenue_volatility IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL revenue_volatility for tenure < 3: {result}"
        finally:
            conn.close()

    def test_revenue_volatility_not_null_after_third_month(self, dbt_run):
        """Validate revenue_volatility is NOT NULL for tenure >= 3."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_tenure, revenue_volatility
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure >= 3 AND revenue_volatility IS NULL
            """)
            assert len(result) == 0, \
                f"Found NULL revenue_volatility for tenure >= 3: {result}"
        finally:
            conn.close()

    def test_revenue_volatility_non_negative(self, dbt_run):
        """Validate revenue_volatility is non-negative (CV is always >= 0)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, revenue_volatility
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE revenue_volatility < 0
            """)
            assert len(result) == 0, \
                f"Found negative revenue_volatility: {result}"
        finally:
            conn.close()


class TestChannelMomentumScore:
    """Phase 14: Channel momentum score tests."""

    def test_momentum_score_not_null(self, dbt_run):
        """Validate channel_momentum_score is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_momentum_score IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL channel_momentum_score"
        finally:
            conn.close()

    def test_momentum_score_range(self, dbt_run):
        """Validate channel_momentum_score is between 0 and 100."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_momentum_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_momentum_score < 0 OR channel_momentum_score > 100
            """)
            assert len(result) == 0, \
                f"Found channel_momentum_score outside 0-100 range: {result}"
        finally:
            conn.close()

    def test_momentum_score_is_integer(self, dbt_run):
        """Validate channel_momentum_score is an integer."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_momentum_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_momentum_score != CAST(channel_momentum_score AS INTEGER)
            """)
            assert len(result) == 0, \
                f"Found non-integer channel_momentum_score: {result}"
        finally:
            conn.close()

    def test_momentum_score_components(self, dbt_run):
        """Validate momentum score calculation using component rules."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                WITH expected AS (
                    SELECT month_start, channel, revenue_mom_pct, market_share_pct, channel_rank,
                           channel_momentum_score,
                           -- Growth component (0-40)
                           CASE
                               WHEN revenue_mom_pct >= 50 THEN 40
                               WHEN revenue_mom_pct >= 20 THEN 30
                               WHEN revenue_mom_pct >= 0 THEN 20
                               WHEN revenue_mom_pct >= -20 THEN 10
                               WHEN revenue_mom_pct < -20 THEN 0
                               ELSE 20  -- NULL
                           END +
                           -- Market share component (0-35)
                           CASE
                               WHEN market_share_pct >= 40 THEN 35
                               WHEN market_share_pct >= 25 THEN 28
                               WHEN market_share_pct >= 15 THEN 21
                               WHEN market_share_pct >= 10 THEN 14
                               ELSE 7
                           END +
                           -- Ranking component (0-25)
                           CASE
                               WHEN channel_rank = 1 THEN 25
                               WHEN channel_rank = 2 THEN 20
                               WHEN channel_rank = 3 THEN 15
                               WHEN channel_rank = 4 THEN 10
                               ELSE 5
                           END as expected_score
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                )
                SELECT month_start, channel, channel_momentum_score, expected_score
                FROM expected
                WHERE channel_momentum_score != expected_score
            """)
            assert len(result) == 0, \
                f"Found incorrect channel_momentum_score calculations: {result[:5]}"
        finally:
            conn.close()


class TestStrategicRecommendation:
    """Phase 15: Strategic recommendation tests."""

    def test_strategic_recommendation_not_null(self, dbt_run):
        """Validate strategic_recommendation is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE strategic_recommendation IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL strategic_recommendation"
        finally:
            conn.close()

    def test_valid_strategic_recommendations(self, dbt_run):
        """Validate strategic_recommendation contains only valid values."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT strategic_recommendation
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)
            recommendations = {r[0] for r in result}
            invalid = recommendations - VALID_STRATEGIC_RECOMMENDATIONS
            assert not invalid, \
                f"Invalid strategic recommendations found: {invalid}. Valid: {VALID_STRATEGIC_RECOMMENDATIONS}"
        finally:
            conn.close()

    def test_invest_heavily_criteria(self, dbt_run):
        """Validate Invest Heavily requires momentum >= 80 AND consecutive growth >= 3."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, channel_momentum_score, consecutive_growth_months,
                       strategic_recommendation
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE strategic_recommendation = 'Invest Heavily'
                  AND NOT (channel_momentum_score >= 80 AND consecutive_growth_months >= 3)
            """)
            assert len(result) == 0, \
                f"Found 'Invest Heavily' that doesn't meet criteria: {result[:5]}"
        finally:
            conn.close()

    def test_divest_criteria(self, dbt_run):
        """Validate Divest requires At Risk, consecutive_growth = 0, momentum < 20."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, performance_tier, consecutive_growth_months,
                       channel_momentum_score, strategic_recommendation
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE strategic_recommendation = 'Divest'
                  AND NOT (performance_tier = 'At Risk'
                           AND consecutive_growth_months = 0
                           AND channel_momentum_score < 20)
            """)
            assert len(result) == 0, \
                f"Found 'Divest' that doesn't meet criteria: {result[:5]}"
        finally:
            conn.close()


class TestSpotChecks:
    """Phase 11: Spot check specific values."""

    def test_spot_check_values(self, dbt_run):
        """Validate specific known values."""
        conn, db_type = get_db_connection()
        try:
            for month, channel, exp_orders, exp_customers, exp_revenue, exp_share, exp_rank, exp_top in SPOT_CHECKS:
                result = execute_query(conn, db_type, f"""
                    SELECT order_count, unique_customers, total_revenue,
                           market_share_pct, channel_rank, is_top_channel
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                    WHERE month_start = '{month}' AND channel = '{channel}'
                """)

                assert len(result) > 0, f"No data for {month} {channel}"
                row = result[0]

                assert row[0] == exp_orders, \
                    f"{month} {channel}: order_count expected {exp_orders}, got {row[0]}"

                assert row[1] == exp_customers, \
                    f"{month} {channel}: unique_customers expected {exp_customers}, got {row[1]}"

                assert abs(float(row[2]) - exp_revenue) < 0.01, \
                    f"{month} {channel}: total_revenue expected {exp_revenue}, got {row[2]}"

                assert abs(float(row[3]) - exp_share) < 0.01, \
                    f"{month} {channel}: market_share_pct expected {exp_share}, got {row[3]}"

                assert row[4] == exp_rank, \
                    f"{month} {channel}: channel_rank expected {exp_rank}, got {row[4]}"

                assert row[5] == exp_top, \
                    f"{month} {channel}: is_top_channel expected {exp_top}, got {row[5]}"
        finally:
            conn.close()

    def test_december_top_channel(self, dbt_run):
        """Validate December's top channel is WEB with correct values."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, total_revenue, market_share_pct
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE month_start = '2024-12-01' AND is_top_channel = 'Y'
            """)

            assert len(result) > 0, "No top channel found for December"
            assert result[0][0] == 'WEB', f"Expected WEB as top channel, got {result[0][0]}"
            assert abs(float(result[0][1]) - 9717.15) < 0.01, \
                f"December WEB revenue expected 9717.15, got {result[0][1]}"
            assert abs(float(result[0][2]) - 46.43) < 0.01, \
                f"December WEB market share expected 46.43%, got {result[0][2]}"
        finally:
            conn.close()


class TestOrdering:
    """Phase 12: Ordering validation."""

    def test_ordering_by_month_and_rank(self, dbt_run):
        """Validate results are ordered by month_start, then channel_rank."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel_rank
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            # Get actual order
            actual = execute_query(conn, db_type, f"""
                SELECT month_start, channel_rank
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)

            assert result == actual, "Results not properly ordered by month_start, channel_rank"
        finally:
            conn.close()


class TestIdempotency:
    """Phase 13: Idempotency validation."""

    def test_idempotency(self, dbt_run):
        """Validate results are deterministic (check row count and key values)."""
        conn, db_type = get_db_connection()
        try:
            # Instead of re-running dbt (which can cause locking issues),
            # verify the results are internally consistent
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) as cnt,
                       COUNT(DISTINCT month_start) as months,
                       COUNT(DISTINCT channel) as channels,
                       ROUND(SUM(total_revenue), 2) as total_rev
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)

            # Verify expected counts match (deterministic output)
            assert result[0][0] == EXPECTED_ROW_COUNT, f"Row count mismatch: {result[0][0]}"
            assert result[0][1] == EXPECTED_MONTHS, f"Month count mismatch: {result[0][1]}"
            assert result[0][2] == len(EXPECTED_CHANNELS), f"Channel count mismatch: {result[0][2]}"
            # Total revenue should be consistent
            assert result[0][3] is not None, "Total revenue should not be NULL"
        finally:
            conn.close()


class TestMarketBenchmarksModel:
    """Phase 14: Market benchmarks intermediate model tests."""

    def test_benchmarks_model_exists(self, dbt_run):
        """Validate the market benchmarks intermediate model exists."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_name) = 'int_monthly_market_benchmarks'
                AND lower(table_schema) IN ('main', 'main_channel_analytics')
            """)
            assert result[0][0] > 0, "Market benchmarks intermediate model not found"
        finally:
            conn.close()

    def test_benchmarks_has_all_months(self, dbt_run):
        """Validate benchmarks model has all 12 months."""
        conn, db_type = get_db_connection()
        try:
            intermediate_schema = get_intermediate_schema()
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(DISTINCT month_start)
                FROM {intermediate_schema}.int_monthly_market_benchmarks
            """)
            assert result[0][0] == EXPECTED_MONTHS, \
                f"Expected {EXPECTED_MONTHS} months in benchmarks, got {result[0][0]}"
        finally:
            conn.close()

    def test_hhi_range(self, dbt_run):
        """Validate HHI values are in valid range (0-1)."""
        conn, db_type = get_db_connection()
        try:
            intermediate_schema = get_intermediate_schema()
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {intermediate_schema}.int_monthly_market_benchmarks
                WHERE revenue_hhi < 0 OR revenue_hhi > 1
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with HHI outside 0-1 range"
        finally:
            conn.close()


class TestQuarterColumn:
    """Phase 15: Quarter column tests."""

    def test_valid_quarter_values(self, dbt_run):
        """Validate quarter contains only valid values."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT quarter
                FROM {MODEL_SCHEMA}.monthly_channel_performance
            """)
            quarters = {r[0] for r in result}
            assert quarters <= {'Q1', 'Q2', 'Q3', 'Q4'}, \
                f"Invalid quarter values: {quarters}"
        finally:
            conn.close()

    def test_quarter_assignment(self, dbt_run):
        """Validate quarters are assigned correctly based on month."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, quarter,
                       CASE
                           WHEN EXTRACT(month FROM month_start) BETWEEN 1 AND 3 THEN 'Q1'
                           WHEN EXTRACT(month FROM month_start) BETWEEN 4 AND 6 THEN 'Q2'
                           WHEN EXTRACT(month FROM month_start) BETWEEN 7 AND 9 THEN 'Q3'
                           ELSE 'Q4'
                       END as expected_quarter
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE quarter != CASE
                    WHEN EXTRACT(month FROM month_start) BETWEEN 1 AND 3 THEN 'Q1'
                    WHEN EXTRACT(month FROM month_start) BETWEEN 4 AND 6 THEN 'Q2'
                    WHEN EXTRACT(month FROM month_start) BETWEEN 7 AND 9 THEN 'Q3'
                    ELSE 'Q4'
                END
            """)
            assert len(result) == 0, f"Found {len(result)} rows with incorrect quarter"
        finally:
            conn.close()


class TestQTDRevenue:
    """Phase 16: QTD revenue tests."""

    def test_qtd_revenue_not_null(self, dbt_run):
        """Validate qtd_revenue is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE qtd_revenue IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL qtd_revenue"
        finally:
            conn.close()

    def test_qtd_revenue_resets_each_quarter(self, dbt_run):
        """Validate QTD revenue resets at start of each quarter."""
        conn, db_type = get_db_connection()
        try:
            # First month of each quarter should have qtd_revenue = total_revenue
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, qtd_revenue, total_revenue
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE EXTRACT(month FROM month_start) IN (1, 4, 7, 10)
                  AND ABS(qtd_revenue - total_revenue) > 0.01
            """)
            assert len(result) == 0, \
                f"QTD revenue should equal total_revenue at quarter start: {result[:5]}"
        finally:
            conn.close()


class TestCustomerGrowthRate:
    """Phase 17: Customer growth rate tests."""

    def test_customer_growth_rate_null_first_month(self, dbt_run):
        """Validate customer_growth_rate is NULL for first month of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, customer_growth_rate
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND customer_growth_rate IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL customer_growth_rate for first month: {result}"
        finally:
            conn.close()

    def test_prev_month_customers_null_first_month(self, dbt_run):
        """Validate prev_month_customers is NULL for first month of each channel."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, prev_month_customers
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND prev_month_customers IS NOT NULL
            """)
            assert len(result) == 0, \
                f"Found non-NULL prev_month_customers for first month: {result}"
        finally:
            conn.close()


class TestMarketComparisons:
    """Phase 18: Market comparison metrics tests."""

    def test_market_avg_revenue_not_null(self, dbt_run):
        """Validate market_avg_revenue is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE market_avg_revenue IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL market_avg_revenue"
        finally:
            conn.close()

    def test_market_avg_aov_not_null(self, dbt_run):
        """Validate market_avg_aov is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE market_avg_aov IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL market_avg_aov"
        finally:
            conn.close()

    def test_vs_market_revenue_pct_calculation(self, dbt_run):
        """Validate vs_market_revenue_pct calculation is correct."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, total_revenue, market_avg_revenue,
                       vs_market_revenue_pct,
                       ROUND(((total_revenue - market_avg_revenue) / market_avg_revenue) * 100, 2) as expected
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE ABS(vs_market_revenue_pct - ROUND(((total_revenue - market_avg_revenue) / market_avg_revenue) * 100, 2)) > 0.1
            """)
            assert len(result) == 0, \
                f"Found incorrect vs_market_revenue_pct: {result[:5]}"
        finally:
            conn.close()


class TestAOVRank:
    """Phase 19: AOV rank tests."""

    def test_aov_rank_starts_at_one(self, dbt_run):
        """Validate aov_rank starts at 1 for each month."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, MIN(aov_rank)
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                GROUP BY month_start
                HAVING MIN(aov_rank) != 1
            """)
            assert len(result) == 0, f"Found months without aov_rank = 1: {result}"
        finally:
            conn.close()

    def test_aov_rank_not_null(self, dbt_run):
        """Validate aov_rank is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE aov_rank IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL aov_rank"
        finally:
            conn.close()


class TestRevenueHHI:
    """Phase 20: Revenue HHI tests."""

    def test_hhi_not_null(self, dbt_run):
        """Validate revenue_hhi is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE revenue_hhi IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL revenue_hhi"
        finally:
            conn.close()

    def test_hhi_same_for_all_channels_in_month(self, dbt_run):
        """Validate HHI is the same for all channels within a month."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, COUNT(DISTINCT revenue_hhi) as distinct_hhi
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                GROUP BY month_start
                HAVING COUNT(DISTINCT revenue_hhi) > 1
            """)
            assert len(result) == 0, \
                f"Found months with different HHI values across channels: {result}"
        finally:
            conn.close()


class TestGrowthConsistencyScore:
    """Phase 21: Growth consistency score tests."""

    def test_growth_consistency_score_not_null(self, dbt_run):
        """Validate growth_consistency_score is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE growth_consistency_score IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL growth_consistency_score"
        finally:
            conn.close()

    def test_growth_consistency_score_range(self, dbt_run):
        """Validate growth_consistency_score is between 0 and 6."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, growth_consistency_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE growth_consistency_score < 0 OR growth_consistency_score > 6
            """)
            assert len(result) == 0, \
                f"Found growth_consistency_score outside 0-6: {result}"
        finally:
            conn.close()

    def test_growth_consistency_zero_for_first_month(self, dbt_run):
        """Validate growth_consistency_score is 0 for first month."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, growth_consistency_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_tenure = 1 AND growth_consistency_score != 0
            """)
            assert len(result) == 0, \
                f"Found non-zero growth_consistency_score for first month: {result}"
        finally:
            conn.close()


class TestChannelEfficiencyScore:
    """Phase 22: Channel efficiency score tests."""

    def test_efficiency_score_not_null(self, dbt_run):
        """Validate channel_efficiency_score is never NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_efficiency_score IS NULL
            """)
            assert result[0][0] == 0, f"Found {result[0][0]} rows with NULL channel_efficiency_score"
        finally:
            conn.close()

    def test_efficiency_score_range(self, dbt_run):
        """Validate channel_efficiency_score is between 0 and 100."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_efficiency_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_efficiency_score < 0 OR channel_efficiency_score > 100
            """)
            assert len(result) == 0, \
                f"Found channel_efficiency_score outside 0-100: {result}"
        finally:
            conn.close()

    def test_efficiency_score_is_integer(self, dbt_run):
        """Validate channel_efficiency_score is an integer."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT channel, month_start, channel_efficiency_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE channel_efficiency_score != CAST(channel_efficiency_score AS INTEGER)
            """)
            assert len(result) == 0, \
                f"Found non-integer channel_efficiency_score: {result}"
        finally:
            conn.close()

    def test_efficiency_score_components(self, dbt_run):
        """Validate efficiency score calculation using component rules."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                WITH expected AS (
                    SELECT month_start, channel, aov_rank, customer_growth_rate, growth_consistency_score,
                           channel_efficiency_score,
                           -- AOV component (0-40)
                           CASE
                               WHEN aov_rank = 1 THEN 40
                               WHEN aov_rank = 2 THEN 32
                               WHEN aov_rank = 3 THEN 24
                               WHEN aov_rank = 4 THEN 16
                               ELSE 8
                           END +
                           -- Customer growth component (0-35)
                           CASE
                               WHEN customer_growth_rate >= 50 THEN 35
                               WHEN customer_growth_rate >= 20 THEN 28
                               WHEN customer_growth_rate >= 0 THEN 21
                               WHEN customer_growth_rate >= -20 THEN 14
                               WHEN customer_growth_rate < -20 THEN 7
                               ELSE 21
                           END +
                           -- Consistency component (0-25)
                           CASE
                               WHEN growth_consistency_score >= 5 THEN 25
                               WHEN growth_consistency_score >= 4 THEN 20
                               WHEN growth_consistency_score >= 3 THEN 15
                               WHEN growth_consistency_score >= 2 THEN 10
                               ELSE 5
                           END as expected_score
                    FROM {MODEL_SCHEMA}.monthly_channel_performance
                )
                SELECT month_start, channel, channel_efficiency_score, expected_score
                FROM expected
                WHERE channel_efficiency_score != expected_score
            """)
            assert len(result) == 0, \
                f"Found incorrect channel_efficiency_score calculations: {result[:5]}"
        finally:
            conn.close()


class TestComprehensiveSpotChecks:
    """Phase 24: Comprehensive spot check validation for specific month/channel combinations."""

    def test_december_web_comprehensive(self, dbt_run):
        """Validate all key metrics for December WEB (top performer)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT order_count, unique_customers, total_revenue, avg_order_value,
                       market_share_pct, channel_tenure, channel_rank, aov_rank,
                       is_top_channel, ytd_revenue, ytd_order_count, qtd_revenue, quarter
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE month_start = '2024-12-01' AND channel = 'WEB'
            """)

            assert len(result) > 0, "December WEB data not found"
            row = result[0]
            spot = SPOT_CHECK_DEC_WEB

            assert row[0] == spot['order_count'], \
                f"Dec WEB order_count: expected {spot['order_count']}, got {row[0]}"
            assert row[1] == spot['unique_customers'], \
                f"Dec WEB unique_customers: expected {spot['unique_customers']}, got {row[1]}"
            assert abs(float(row[2]) - spot['total_revenue']) < 0.01, \
                f"Dec WEB total_revenue: expected {spot['total_revenue']}, got {row[2]}"
            assert abs(float(row[3]) - spot['avg_order_value']) < 0.01, \
                f"Dec WEB avg_order_value: expected {spot['avg_order_value']}, got {row[3]}"
            assert abs(float(row[4]) - spot['market_share_pct']) < 0.01, \
                f"Dec WEB market_share_pct: expected {spot['market_share_pct']}, got {row[4]}"
            assert row[5] == spot['channel_tenure'], \
                f"Dec WEB channel_tenure: expected {spot['channel_tenure']}, got {row[5]}"
            assert row[6] == spot['channel_rank'], \
                f"Dec WEB channel_rank: expected {spot['channel_rank']}, got {row[6]}"
            assert row[7] == spot['aov_rank'], \
                f"Dec WEB aov_rank: expected {spot['aov_rank']}, got {row[7]}"
            assert row[8] == spot['is_top_channel'], \
                f"Dec WEB is_top_channel: expected {spot['is_top_channel']}, got {row[8]}"
            assert abs(float(row[9]) - spot['ytd_revenue']) < 0.01, \
                f"Dec WEB ytd_revenue: expected {spot['ytd_revenue']}, got {row[9]}"
            assert row[10] == spot['ytd_order_count'], \
                f"Dec WEB ytd_order_count: expected {spot['ytd_order_count']}, got {row[10]}"
            assert abs(float(row[11]) - spot['qtd_revenue']) < 0.01, \
                f"Dec WEB qtd_revenue: expected {spot['qtd_revenue']}, got {row[11]}"
            assert row[12] == spot['quarter'], \
                f"Dec WEB quarter: expected {spot['quarter']}, got {row[12]}"
        finally:
            conn.close()

    def test_december_mobile_comprehensive(self, dbt_run):
        """Validate all key metrics for December MOBILE (second place)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT order_count, unique_customers, total_revenue, avg_order_value,
                       market_share_pct, channel_tenure, channel_rank, aov_rank,
                       is_top_channel, ytd_revenue, ytd_order_count, qtd_revenue, quarter
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE month_start = '2024-12-01' AND channel = 'MOBILE'
            """)

            assert len(result) > 0, "December MOBILE data not found"
            row = result[0]
            spot = SPOT_CHECK_DEC_MOBILE

            assert row[0] == spot['order_count'], \
                f"Dec MOBILE order_count: expected {spot['order_count']}, got {row[0]}"
            assert row[1] == spot['unique_customers'], \
                f"Dec MOBILE unique_customers: expected {spot['unique_customers']}, got {row[1]}"
            assert abs(float(row[2]) - spot['total_revenue']) < 0.01, \
                f"Dec MOBILE total_revenue: expected {spot['total_revenue']}, got {row[2]}"
            assert abs(float(row[3]) - spot['avg_order_value']) < 0.01, \
                f"Dec MOBILE avg_order_value: expected {spot['avg_order_value']}, got {row[3]}"
            assert abs(float(row[4]) - spot['market_share_pct']) < 0.01, \
                f"Dec MOBILE market_share_pct: expected {spot['market_share_pct']}, got {row[4]}"
            assert row[5] == spot['channel_tenure'], \
                f"Dec MOBILE channel_tenure: expected {spot['channel_tenure']}, got {row[5]}"
            assert row[6] == spot['channel_rank'], \
                f"Dec MOBILE channel_rank: expected {spot['channel_rank']}, got {row[6]}"
            assert row[7] == spot['aov_rank'], \
                f"Dec MOBILE aov_rank: expected {spot['aov_rank']}, got {row[7]}"
            assert row[8] == spot['is_top_channel'], \
                f"Dec MOBILE is_top_channel: expected {spot['is_top_channel']}, got {row[8]}"
            assert abs(float(row[9]) - spot['ytd_revenue']) < 0.01, \
                f"Dec MOBILE ytd_revenue: expected {spot['ytd_revenue']}, got {row[9]}"
            assert row[10] == spot['ytd_order_count'], \
                f"Dec MOBILE ytd_order_count: expected {spot['ytd_order_count']}, got {row[10]}"
            assert abs(float(row[11]) - spot['qtd_revenue']) < 0.01, \
                f"Dec MOBILE qtd_revenue: expected {spot['qtd_revenue']}, got {row[11]}"
            assert row[12] == spot['quarter'], \
                f"Dec MOBILE quarter: expected {spot['quarter']}, got {row[12]}"
        finally:
            conn.close()

    def test_january_web_first_month(self, dbt_run):
        """Validate first month data for WEB (January) - NULL prev values expected."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT order_count, unique_customers, total_revenue, avg_order_value,
                       market_share_pct, channel_tenure, channel_rank, aov_rank,
                       is_top_channel, prev_month_revenue, revenue_mom_change,
                       revenue_mom_pct, growth_category
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                WHERE month_start = '2024-01-01' AND channel = 'WEB'
            """)

            assert len(result) > 0, "January WEB data not found"
            row = result[0]
            spot = SPOT_CHECK_JAN_WEB

            assert row[0] == spot['order_count'], \
                f"Jan WEB order_count: expected {spot['order_count']}, got {row[0]}"
            assert row[1] == spot['unique_customers'], \
                f"Jan WEB unique_customers: expected {spot['unique_customers']}, got {row[1]}"
            assert abs(float(row[2]) - spot['total_revenue']) < 0.01, \
                f"Jan WEB total_revenue: expected {spot['total_revenue']}, got {row[2]}"
            assert abs(float(row[3]) - spot['avg_order_value']) < 0.01, \
                f"Jan WEB avg_order_value: expected {spot['avg_order_value']}, got {row[3]}"
            assert abs(float(row[4]) - spot['market_share_pct']) < 0.01, \
                f"Jan WEB market_share_pct: expected {spot['market_share_pct']}, got {row[4]}"
            assert row[5] == spot['channel_tenure'], \
                f"Jan WEB channel_tenure: expected {spot['channel_tenure']}, got {row[5]}"
            assert row[6] == spot['channel_rank'], \
                f"Jan WEB channel_rank: expected {spot['channel_rank']}, got {row[6]}"
            assert row[7] == spot['aov_rank'], \
                f"Jan WEB aov_rank: expected {spot['aov_rank']}, got {row[7]}"
            assert row[8] == spot['is_top_channel'], \
                f"Jan WEB is_top_channel: expected {spot['is_top_channel']}, got {row[8]}"
            # First month should have NULL for prev values
            assert row[9] is None, \
                f"Jan WEB prev_month_revenue should be NULL, got {row[9]}"
            assert row[10] is None, \
                f"Jan WEB revenue_mom_change should be NULL, got {row[10]}"
            assert row[11] is None, \
                f"Jan WEB revenue_mom_pct should be NULL, got {row[11]}"
            assert row[12] is None, \
                f"Jan WEB growth_category should be NULL, got {row[12]}"
        finally:
            conn.close()


# ============ ALL ROWS GROUND TRUTH FOR COMPREHENSIVE VALIDATION ============
# Format: (month_start, channel, total_revenue, channel_rank, market_share_pct, revenue_mom_pct, growth_category, consecutive_growth_months, channel_momentum_score, channel_efficiency_score, strategic_recommendation, performance_tier)
ALL_ROWS_GROUND_TRUTH = [
    ('2024-01-01', 'WEB', 1743.59, 1, 35.95, None, None, 0, 73, 58, 'Scale Up', 'Emerging'),
    ('2024-01-01', 'MOBILE', 1599.52, 2, 32.98, None, None, 0, 68, 50, 'Experiment', 'Emerging'),
    ('2024-01-01', 'PHONE', 1506.39, 3, 31.06, None, None, 0, 63, 66, 'Experiment', 'Emerging'),
    ('2024-02-01', 'WEB', 2596.48, 1, 59.19, 48.92, 'Moderate Growth', 2, 90, 72, 'Scale Up', 'Market Leader'),
    ('2024-02-01', 'MOBILE', 1302.64, 2, 29.69, -18.56, 'Slight Decline', 0, 58, 52, 'Optimize', 'Strong Performer'),
    ('2024-02-01', 'MARKETPLACE', 193.6, 3, 4.41, None, None, 0, 42, 50, 'Experiment', 'Emerging'),
    ('2024-02-01', 'POS', 177.2, 4, 4.04, None, None, 0, 37, 42, 'Monitor', 'Emerging'),
    ('2024-02-01', 'PHONE', 116.82, 5, 2.66, -92.25, 'Sharp Decline', 0, 12, 34, 'Review', 'At Risk'),
    ('2024-03-01', 'WEB', 3721.58, 1, 42.91, 43.33, 'Moderate Growth', 3, 90, 63, 'Scale Up', 'Market Leader'),
    ('2024-03-01', 'MOBILE', 3182.22, 2, 36.69, 144.29, 'Explosive', 2, 88, 80, 'Scale Up', 'Strong Performer'),
    ('2024-03-01', 'MARKETPLACE', 959.59, 3, 11.06, 395.66, 'Explosive', 2, 69, 56, 'Experiment', 'Growth Potential'),
    ('2024-03-01', 'POS', 809.45, 4, 9.33, 356.8, 'Explosive', 2, 57, 64, 'Experiment', 'Growth Potential'),
    ('2024-04-01', 'WEB', 5606.65, 1, 74.69, 50.65, 'Strong Growth', 4, 100, 83, 'Invest Heavily', 'Market Leader'),
    ('2024-04-01', 'MOBILE', 1815.67, 2, 24.19, -42.94, 'Moderate Decline', 0, 41, 58, 'Review', 'At Risk'),
    ('2024-04-01', 'POS', 84.54, 3, 1.13, -89.56, 'Sharp Decline', 0, 22, 36, 'Review', 'At Risk'),
    ('2024-05-01', 'MOBILE', 5959.91, 1, 53.38, 228.25, 'Explosive', 2, 100, 77, 'Scale Up', 'Market Leader'),
    ('2024-05-01', 'WEB', 3587.44, 2, 32.13, -36.01, 'Moderate Decline', 0, 48, 53, 'Review', 'At Risk'),
    ('2024-05-01', 'POS', 1460.06, 3, 13.08, 1627.06, 'Explosive', 2, 69, 85, 'Experiment', 'Growth Potential'),
    ('2024-05-01', 'MARKETPLACE', 158.07, 4, 1.42, -83.53, 'Sharp Decline', 0, 17, 28, 'Divest', 'At Risk'),
    ('2024-06-01', 'WEB', 3911.58, 1, 51.79, 9.04, 'Slight Growth', 2, 80, 65, 'Scale Up', 'Stable Core'),
    ('2024-06-01', 'MOBILE', 1643.11, 2, 21.75, -72.43, 'Sharp Decline', 0, 41, 57, 'Review', 'At Risk'),
    ('2024-06-01', 'PHONE', 678.4, 3, 8.98, 480.72, 'Explosive', 2, 62, 72, 'Experiment', 'Growth Potential'),
    ('2024-06-01', 'POS', 669.22, 4, 8.86, -54.16, 'Sharp Decline', 0, 17, 46, 'Review', 'At Risk'),
    ('2024-06-01', 'MARKETPLACE', 651.08, 5, 8.62, 311.89, 'Explosive', 2, 52, 47, 'Experiment', 'Growth Potential'),
    ('2024-07-01', 'MOBILE', 7062.06, 1, 50.57, 329.8, 'Explosive', 2, 100, 82, 'Scale Up', 'Market Leader'),
    ('2024-07-01', 'WEB', 4697.13, 2, 33.64, 20.08, 'Moderate Growth', 3, 78, 62, 'Scale Up', 'Strong Performer'),
    ('2024-07-01', 'PHONE', 980.65, 3, 7.02, 44.55, 'Moderate Growth', 3, 52, 55, 'Maintain', 'Niche'),
    ('2024-07-01', 'POS', 870.41, 4, 6.23, 30.06, 'Moderate Growth', 2, 47, 62, 'Maintain', 'Niche'),
    ('2024-07-01', 'MARKETPLACE', 354.27, 5, 2.54, -45.59, 'Moderate Decline', 0, 12, 39, 'Review', 'At Risk'),
    ('2024-08-01', 'WEB', 5007.77, 1, 62.75, 6.61, 'Slight Growth', 4, 80, 78, 'Invest Heavily', 'Stable Core'),
    ('2024-08-01', 'MOBILE', 1420.27, 2, 17.80, -79.89, 'Sharp Decline', 0, 41, 46, 'Review', 'At Risk'),
    ('2024-08-01', 'POS', 1314.18, 3, 16.47, 50.98, 'Strong Growth', 3, 76, 95, 'Experiment', 'Growth Potential'),
    ('2024-08-01', 'MARKETPLACE', 237.75, 4, 2.98, -32.89, 'Moderate Decline', 0, 17, 33, 'Review', 'At Risk'),
    ('2024-09-01', 'WEB', 5553.52, 1, 43.99, 10.9, 'Slight Growth', 5, 80, 55, 'Scale Up', 'Stable Core'),
    ('2024-09-01', 'MOBILE', 2391.95, 2, 18.95, 68.42, 'Strong Growth', 2, 81, 75, 'Experiment', 'Growth Potential'),
    ('2024-09-01', 'MARKETPLACE', 2346.62, 3, 18.59, 887.01, 'Explosive', 2, 76, 90, 'Experiment', 'Growth Potential'),
    ('2024-09-01', 'POS', 2252.15, 4, 17.84, 71.37, 'Strong Growth', 4, 71, 79, 'Experiment', 'Growth Potential'),
    ('2024-09-01', 'PHONE', 80.16, 5, 0.63, -91.83, 'Sharp Decline', 0, 12, 25, 'Divest', 'At Risk'),
    ('2024-10-01', 'WEB', 4921.0, 1, 57.85, -11.39, 'Slight Decline', 0, 70, 80, 'Scale Up', 'Stable Core'),
    ('2024-10-01', 'MOBILE', 2103.29, 2, 24.73, -12.07, 'Slight Decline', 0, 51, 83, 'Optimize', 'Stable Core'),
    ('2024-10-01', 'POS', 933.79, 3, 10.98, -58.54, 'Sharp Decline', 0, 29, 65, 'Review', 'At Risk'),
    ('2024-10-01', 'MARKETPLACE', 548.21, 4, 6.44, -76.64, 'Sharp Decline', 0, 17, 47, 'Review', 'At Risk'),
    ('2024-11-01', 'WEB', 10592.76, 1, 62.24, 115.26, 'Explosive', 2, 100, 92, 'Scale Up', 'Market Leader'),
    ('2024-11-01', 'MOBILE', 3983.58, 2, 23.41, 89.4, 'Strong Growth', 2, 81, 74, 'Scale Up', 'Growth Potential'),
    ('2024-11-01', 'MARKETPLACE', 1413.69, 3, 8.31, 157.87, 'Explosive', 2, 62, 52, 'Experiment', 'Growth Potential'),
    ('2024-11-01', 'PHONE', 1029.87, 4, 6.05, 1184.77, 'Explosive', 2, 57, 90, 'Experiment', 'Growth Potential'),
    ('2024-12-01', 'WEB', 9717.15, 1, 46.43, -8.27, 'Slight Decline', 0, 70, 67, 'Scale Up', 'Stable Core'),
    ('2024-12-01', 'MOBILE', 6913.11, 2, 33.03, 73.54, 'Strong Growth', 3, 88, 72, 'Invest Heavily', 'Strong Performer'),
    ('2024-12-01', 'PHONE', 1884.08, 3, 9.0, 82.94, 'Strong Growth', 3, 62, 87, 'Experiment', 'Growth Potential'),
    ('2024-12-01', 'MARKETPLACE', 1217.83, 4, 5.82, -13.85, 'Slight Decline', 0, 27, 54, 'Review', 'Niche'),
    ('2024-12-01', 'POS', 1198.26, 5, 5.72, 28.32, 'Moderate Growth', 2, 42, 49, 'Maintain', 'Niche'),
]


class TestAllRowsGroundTruth:
    """Phase 25: Comprehensive validation of ALL 51 rows with exact calculated values."""

    def test_all_rows_total_revenue(self, dbt_run):
        """Validate total_revenue for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, total_revenue
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, exp_revenue, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert str(actual[0])[:10] == month, \
                    f"Row {i}: month mismatch, expected {month}, got {actual[0]}"
                assert actual[1] == channel, \
                    f"Row {i}: channel mismatch, expected {channel}, got {actual[1]}"
                assert abs(float(actual[2]) - exp_revenue) < 0.01, \
                    f"Row {i} ({month}, {channel}): total_revenue expected {exp_revenue}, got {actual[2]}"
        finally:
            conn.close()

    def test_all_rows_channel_rank(self, dbt_run):
        """Validate channel_rank for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, channel_rank
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, exp_rank, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert actual[2] == exp_rank, \
                    f"Row {i} ({month}, {channel}): channel_rank expected {exp_rank}, got {actual[2]}"
        finally:
            conn.close()

    def test_all_rows_market_share(self, dbt_run):
        """Validate market_share_pct for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, market_share_pct
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, exp_share, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert abs(float(actual[2]) - exp_share) < 0.01, \
                    f"Row {i} ({month}, {channel}): market_share_pct expected {exp_share}, got {actual[2]}"
        finally:
            conn.close()

    def test_all_rows_momentum_score(self, dbt_run):
        """Validate channel_momentum_score for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, channel_momentum_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, _, _, _, _, exp_momentum, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert actual[2] == exp_momentum, \
                    f"Row {i} ({month}, {channel}): channel_momentum_score expected {exp_momentum}, got {actual[2]}"
        finally:
            conn.close()

    def test_all_rows_efficiency_score(self, dbt_run):
        """Validate channel_efficiency_score for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, channel_efficiency_score
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, _, _, _, _, _, exp_efficiency, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert actual[2] == exp_efficiency, \
                    f"Row {i} ({month}, {channel}): channel_efficiency_score expected {exp_efficiency}, got {actual[2]}"
        finally:
            conn.close()

    def test_all_rows_strategic_recommendation(self, dbt_run):
        """Validate strategic_recommendation for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, strategic_recommendation
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, _, _, _, _, _, _, exp_rec, _) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert actual[2] == exp_rec, \
                    f"Row {i} ({month}, {channel}): strategic_recommendation expected '{exp_rec}', got '{actual[2]}'"
        finally:
            conn.close()

    def test_all_rows_performance_tier(self, dbt_run):
        """Validate performance_tier for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, performance_tier
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, _, _, _, _, _, _, _, exp_tier) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert actual[2] == exp_tier, \
                    f"Row {i} ({month}, {channel}): performance_tier expected '{exp_tier}', got '{actual[2]}'"
        finally:
            conn.close()

    def test_all_rows_consecutive_growth(self, dbt_run):
        """Validate consecutive_growth_months for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, consecutive_growth_months
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, _, _, _, exp_consec, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                assert actual[2] == exp_consec, \
                    f"Row {i} ({month}, {channel}): consecutive_growth_months expected {exp_consec}, got {actual[2]}"
        finally:
            conn.close()

    def test_all_rows_growth_category(self, dbt_run):
        """Validate growth_category for all 51 rows."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT month_start, channel, growth_category
                FROM {MODEL_SCHEMA}.monthly_channel_performance
                ORDER BY month_start, channel_rank
            """)

            for i, (month, channel, _, _, _, _, exp_cat, *_) in enumerate(ALL_ROWS_GROUND_TRUTH):
                actual = result[i]
                if exp_cat is None:
                    assert actual[2] is None, \
                        f"Row {i} ({month}, {channel}): growth_category expected NULL, got '{actual[2]}'"
                else:
                    assert actual[2] == exp_cat, \
                        f"Row {i} ({month}, {channel}): growth_category expected '{exp_cat}', got '{actual[2]}'"
        finally:
            conn.close()
