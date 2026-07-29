"""
Tests for dbt-product-sales-velocity task.

Validates product sales velocity models:
- stg_order_lines__sales
- int_product_daily_sales
- int_product_monthly_sales
- int_product_sales_metrics
- product_sales_velocity
"""

import os
import subprocess
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


# ============ CONSTANTS ============

SCHEMA = "main_velocity_analytics"

EXPECTED_COLUMNS = [
    "product_id",
    "product_name",
    "category_id",
    "total_units_sold",
    "total_orders",
    "total_gross_revenue",
    "total_net_revenue",
    "total_discount",
    "avg_unit_price",
    "discount_rate",
    "days_with_sales",
    "first_sale_date",
    "last_sale_date",
    "active_days",
    "sales_frequency",
    "avg_daily_units",
    "avg_daily_revenue",
    "daily_units_std_dev",
    "velocity_cv",
    "first_half_units",
    "second_half_units",
    "velocity_change_ratio",
    "revenue_rank",
    "velocity_percentile",
    "velocity_tier",
    "consistency_tier",
    "velocity_trend",
    "months_active",
    "first_month_units",
    "last_month_units",
    "month_velocity_change",
    "rolling_3m_avg_units",
    "recent_3m_units",
    "recent_share_pct",
    "monthly_cv",
    "category_avg_daily_units",
    "vs_category_velocity",
    "category_velocity_tier",
    "category_velocity_rank",
    "category_velocity_percentile",
    "monthly_trend",
    "momentum_score",
    "momentum_tier",
    "seasonality_index",
    "volatility_band",
    "demand_pattern",
    "performance_score",
    "performance_grade",
]

VALID_VELOCITY_TIERS = ["Elite", "High", "Medium", "Low", "Minimal"]
VALID_CONSISTENCY_TIERS = [
    "Very Consistent",
    "Consistent",
    "Variable",
    "Highly Variable",
    "Insufficient Data",
]
VALID_VELOCITY_TRENDS = [
    "Accelerating",
    "Growing",
    "Stable",
    "Slowing",
    "Declining",
    "New Product",
    "Insufficient Data",
]
VALID_CATEGORY_VELOCITY_TIERS = ["Above", "Near", "Below"]
VALID_MONTHLY_TRENDS = [
    "Rapid Growth",
    "Growth",
    "Stable",
    "Decline",
    "Rapid Decline",
    "New",
]
VALID_DEMAND_PATTERNS = [
    "Breakout",
    "Seasonal",
    "Steady",
    "Fading",
    "New Entry",
    "Long Tail",
    "Unclassified",
]
VALID_PERFORMANCE_GRADES = ["A", "B", "C", "D", "F"]
VALID_MOMENTUM_TIERS = ["Hot", "Warm", "Cool", "Cold"]
VALID_VOLATILITY_BANDS = [
    "Insufficient",
    "Highly Volatile",
    "Volatile",
    "Moderate",
    "Stable",
]

STAGING_REQUIRED_COLUMNS = [
    "order_line_id",
    "order_id",
    "product_id",
    "product_name",
    "sale_date",
    "units_sold",
    "unit_price",
    "gross_line_value",
    "discount_amount",
    "net_line_value",
]

DAILY_SALES_REQUIRED_COLUMNS = [
    "product_id",
    "sale_date",
    "daily_units",
    "daily_orders",
    "daily_gross_revenue",
    "daily_discount",
    "daily_net_revenue",
]

MONTHLY_SALES_REQUIRED_COLUMNS = [
    "product_id",
    "sale_month",
    "monthly_units",
    "monthly_orders",
    "monthly_net_revenue",
]

METRICS_REQUIRED_COLUMNS = [
    "product_id",
    "product_name",
    "total_units_sold",
    "total_orders",
    "total_gross_revenue",
    "total_discount",
    "total_net_revenue",
    "days_with_sales",
    "first_sale_date",
    "last_sale_date",
    "active_days",
    "avg_daily_units",
    "avg_daily_revenue",
    "daily_units_std_dev",
    "first_half_units",
    "second_half_units",
]


class TestModelExistence:
    """Verify required models exist."""

    def test_staging_model_exists(self):
        """Verify the stg_order_lines__sales staging model exists in the database."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_staging', 'main')
                AND lower(table_name) = 'stg_order_lines__sales'
            """)
            assert int(result) >= 1, "Staging model stg_order_lines__sales does not exist"
        finally:
            conn.close()

    def test_daily_sales_model_exists(self):
        """Verify the int_product_daily_sales intermediate model exists in the database."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate', 'main')
                AND lower(table_name) = 'int_product_daily_sales'
            """)
            assert int(result) >= 1, "Intermediate model int_product_daily_sales does not exist"
        finally:
            conn.close()

    def test_monthly_sales_model_exists(self):
        """Verify the int_product_monthly_sales intermediate model exists in the database."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate', 'main')
                AND lower(table_name) = 'int_product_monthly_sales'
            """)
            assert int(result) >= 1, "Intermediate model int_product_monthly_sales does not exist"
        finally:
            conn.close()

    def test_metrics_model_exists(self):
        """Verify the int_product_sales_metrics intermediate model exists in the database."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate', 'main')
                AND lower(table_name) = 'int_product_sales_metrics'
            """)
            assert int(result) >= 1, "Intermediate model int_product_sales_metrics does not exist"
        finally:
            conn.close()

    def test_mart_model_exists(self):
        """Verify the product_sales_velocity mart model exists in the database."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = '{SCHEMA}'
                AND lower(table_name) = 'product_sales_velocity'
            """)
            assert int(result) == 1, "Mart model product_sales_velocity does not exist"
        finally:
            conn.close()

    def test_mart_model_is_table(self):
        """Verify the mart model is materialized as a BASE TABLE, not a view."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT table_type FROM information_schema.tables
                WHERE lower(table_schema) = '{SCHEMA}'
                AND lower(table_name) = 'product_sales_velocity'
            """)
            assert result == "BASE TABLE", f"Mart model should be a TABLE, but is {result}"
        finally:
            conn.close()


class TestColumnStructure:
    """Verify column structure and order."""

    def test_mart_column_count(self):
        """Verify the product_sales_velocity mart has exactly 48 columns."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.columns
                WHERE lower(table_schema) = '{SCHEMA}'
                AND lower(table_name) = 'product_sales_velocity'
            """)
            assert int(result) == 48, f"Expected 48 columns, found {result}"
        finally:
            conn.close()

    def test_mart_column_names(self):
        """Verify the mart column names and ordering match the expected specification."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT lower(column_name) FROM information_schema.columns
                WHERE lower(table_schema) = '{SCHEMA}'
                AND lower(table_name) = 'product_sales_velocity'
                ORDER BY ordinal_position
            """)
            actual_columns = [row[0] for row in result]
            assert actual_columns == EXPECTED_COLUMNS, \
                f"Column mismatch. Expected: {EXPECTED_COLUMNS}, Actual: {actual_columns}"
        finally:
            conn.close()

    def test_staging_has_required_columns(self):
        """Verify all required columns exist in the stg_order_lines__sales staging model."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT lower(column_name) FROM information_schema.columns
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_staging', 'main')
                AND lower(table_name) = 'stg_order_lines__sales'
            """)
            actual = [row[0] for row in result]
            for col in STAGING_REQUIRED_COLUMNS:
                assert col.lower() in actual, f"Missing column {col} in staging model"
        finally:
            conn.close()

    def test_daily_sales_has_required_columns(self):
        """Verify all required columns exist in the int_product_daily_sales model."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT lower(column_name) FROM information_schema.columns
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate', 'main')
                AND lower(table_name) = 'int_product_daily_sales'
            """)
            actual = [row[0] for row in result]
            for col in DAILY_SALES_REQUIRED_COLUMNS:
                assert col.lower() in actual, f"Missing column {col} in daily sales model"
        finally:
            conn.close()

    def test_monthly_sales_has_required_columns(self):
        """Verify all required columns exist in the int_product_monthly_sales model."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT lower(column_name) FROM information_schema.columns
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate', 'main')
                AND lower(table_name) = 'int_product_monthly_sales'
            """)
            actual = [row[0] for row in result]
            for col in MONTHLY_SALES_REQUIRED_COLUMNS:
                assert col.lower() in actual, f"Missing column {col} in monthly sales model"
        finally:
            conn.close()

    def test_metrics_has_required_columns(self):
        """Verify all required columns exist in the int_product_sales_metrics model."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT lower(column_name) FROM information_schema.columns
                WHERE lower(table_schema) IN ('{SCHEMA}', 'main_intermediate', 'main')
                AND lower(table_name) = 'int_product_sales_metrics'
            """)
            actual = [row[0] for row in result]
            for col in METRICS_REQUIRED_COLUMNS:
                assert col.lower() in actual, f"Missing column {col} in metrics model"
        finally:
            conn.close()


class TestDataQuality:
    """Tests for data quality and integrity."""

    def test_no_null_product_ids(self):
        """Verify there are no NULL values in the product_id column."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE product_id IS NULL
            """)
            assert int(result) == 0, f"Found {result} rows with NULL product_id"
        finally:
            conn.close()

    def test_no_null_category_ids(self):
        """Verify there are no NULL values in the category_id column."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE category_id IS NULL
            """)
            assert int(result) == 0, f"Found {result} rows with NULL category_id"
        finally:
            conn.close()


class TestRangesAndValidity:
    """Tests for numeric ranges and valid values."""

    def test_velocity_percentiles_in_range(self):
        """Verify all velocity_percentile values are within the 1-100 range."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_percentile < 1 OR velocity_percentile > 100
            """)
            assert int(result) == 0, f"Found {result} rows with velocity_percentile outside 1-100"
        finally:
            conn.close()

    def test_sales_frequency_range(self):
        """Verify all sales_frequency values are within the 0-100 percentage range."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE sales_frequency < 0 OR sales_frequency > 100
            """)
            assert int(result) == 0, f"Found {result} rows with sales_frequency outside 0-100 range"
        finally:
            conn.close()

    def test_discount_rate_non_negative(self):
        """Verify no products have a negative discount_rate."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE discount_rate < 0
            """)
            assert int(result) == 0, f"Found {result} rows with negative discount_rate"
        finally:
            conn.close()

    def test_valid_velocity_tiers(self):
        """Verify all velocity_tier values are in the allowed set: Elite, High, Medium, Low, Minimal."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT velocity_tier FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_VELOCITY_TIERS, f"Invalid velocity_tier: {val}"
        finally:
            conn.close()

    def test_valid_consistency_tiers(self):
        """Verify all consistency_tier values are in the allowed set."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT consistency_tier FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_CONSISTENCY_TIERS, f"Invalid consistency_tier: {val}"
        finally:
            conn.close()

    def test_valid_velocity_trends(self):
        """Verify all velocity_trend values are in the allowed set."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT velocity_trend FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_VELOCITY_TRENDS, f"Invalid velocity_trend: {val}"
        finally:
            conn.close()

    def test_valid_category_velocity_tiers(self):
        """Verify all category_velocity_tier values are Above, Near, or Below."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT category_velocity_tier FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_CATEGORY_VELOCITY_TIERS, f"Invalid category_velocity_tier: {val}"
        finally:
            conn.close()

    def test_valid_monthly_trends(self):
        """Verify all monthly_trend values are in the allowed set."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT monthly_trend FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_MONTHLY_TRENDS, f"Invalid monthly_trend: {val}"
        finally:
            conn.close()

    def test_valid_demand_patterns(self):
        """Verify all demand_pattern values are in the allowed set."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT demand_pattern FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_DEMAND_PATTERNS, f"Invalid demand_pattern: {val}"
        finally:
            conn.close()

    def test_valid_performance_grades(self):
        """Verify all performance_grade values are A, B, C, D, or F."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT performance_grade FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_PERFORMANCE_GRADES, f"Invalid performance_grade: {val}"
        finally:
            conn.close()

    def test_vs_category_velocity_consistency(self):
        """Verify vs_category_velocity equals avg_daily_units minus category_avg_daily_units."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE abs(cast(avg_daily_units - category_avg_daily_units as double) - cast(vs_category_velocity as double)) > 0.01
            """)
            assert int(result) == 0, "vs_category_velocity must equal avg_daily_units - category_avg_daily_units"
        finally:
            conn.close()

    def test_valid_momentum_tiers(self):
        """Verify all momentum_tier values are Hot, Warm, Cool, or Cold."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT momentum_tier FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_MOMENTUM_TIERS, f"Invalid momentum_tier: {val}"
        finally:
            conn.close()

    def test_valid_volatility_bands(self):
        """Verify all volatility_band values are in the allowed set."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT DISTINCT volatility_band FROM {SCHEMA}.product_sales_velocity
            """)
            actual_values = [row[0] for row in result]
            for val in actual_values:
                assert val in VALID_VOLATILITY_BANDS, f"Invalid volatility_band: {val}"
        finally:
            conn.close()


class TestTierLogic:
    """Tests for tier classification thresholds."""

    def test_elite_tier_threshold(self):
        """Verify Elite tier products have velocity_percentile >= 95."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_tier = 'Elite' AND velocity_percentile < 95
            """)
            assert int(result) == 0, f"Found {result} Elite tier products with velocity_percentile < 95"
        finally:
            conn.close()

    def test_high_tier_threshold(self):
        """Verify High tier products have velocity_percentile in 75-94 range."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_tier = 'High' AND (velocity_percentile < 75 OR velocity_percentile >= 95)
            """)
            assert int(result) == 0, f"Found {result} High tier products outside 75-94 percentile range"
        finally:
            conn.close()

    def test_minimal_tier_threshold(self):
        """Verify Minimal tier products have velocity_percentile < 15."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_tier = 'Minimal' AND velocity_percentile >= 15
            """)
            assert int(result) == 0, f"Found {result} Minimal tier products with velocity_percentile >= 15"
        finally:
            conn.close()

    def test_category_velocity_tier_thresholds(self):
        """Verify Above/Near/Below category velocity tiers match their vs_category_velocity thresholds."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE category_velocity_tier = 'Above' AND vs_category_velocity < 0.50
            """)
            assert int(result) == 0, "Found 'Above' category_velocity_tier below 0.50"

            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE category_velocity_tier = 'Below' AND vs_category_velocity > -0.50
            """)
            assert int(result) == 0, "Found 'Below' category_velocity_tier above -0.50"

            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE category_velocity_tier = 'Near'
                  AND (vs_category_velocity <= -0.50 OR vs_category_velocity >= 0.50)
            """)
            assert int(result) == 0, "Found 'Near' category_velocity_tier outside (-0.50, 0.50)"
        finally:
            conn.close()


class TestMonthlyLogic:
    """Tests for monthly metrics and trends."""

    def test_month_velocity_change_null_for_new(self):
        """Verify new products (months_active < 2) have NULL monthly change and 'New' trend."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE months_active < 2 AND (month_velocity_change IS NOT NULL
                    OR first_month_units IS NOT NULL OR last_month_units IS NOT NULL
                    OR monthly_trend != 'New')
            """)
            assert int(result) == 0, "New products must have NULL monthly change and 'New' trend"
        finally:
            conn.close()

    def test_rolling_3m_null_when_fewer_months(self):
        """Verify rolling_3m_avg_units is NULL for products with fewer than 3 active months."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE months_active < 3 AND rolling_3m_avg_units IS NOT NULL
            """)
            assert int(result) == 0, "rolling_3m_avg_units should be NULL for months_active < 3"
        finally:
            conn.close()

    def test_recent_3m_units_null_when_fewer_months(self):
        """Verify recent_3m_units is NULL for products with fewer than 3 active months."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE months_active < 3 AND recent_3m_units IS NOT NULL
            """)
            assert int(result) == 0, "recent_3m_units should be NULL for months_active < 3"
        finally:
            conn.close()

    def test_recent_share_pct_range(self):
        """Verify recent_share_pct is between 0 and 100 for all products."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE recent_share_pct < 0 OR recent_share_pct > 100
            """)
            assert int(result) == 0, "recent_share_pct should be between 0 and 100"
        finally:
            conn.close()

    def test_recent_share_pct_null_when_fewer_months(self):
        """Verify recent_share_pct is NULL when months_active < 3 or total_units_sold is 0."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE (months_active < 3 OR total_units_sold = 0) AND recent_share_pct IS NOT NULL
            """)
            assert int(result) == 0, "recent_share_pct should be NULL when months_active < 3 or total_units_sold = 0"
        finally:
            conn.close()

    def test_seasonality_index_null_rules(self):
        """Verify seasonality_index is NULL when months_active < 2 or total_units_sold is 0."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE (months_active < 2 OR total_units_sold = 0)
                  AND seasonality_index IS NOT NULL
            """)
            assert int(result) == 0, "seasonality_index should be NULL when months_active < 2 or avg is 0"
        finally:
            conn.close()

    def test_seasonality_index_positive(self):
        """Verify seasonality_index is >= 1 for all non-NULL values."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE seasonality_index IS NOT NULL AND seasonality_index < 1
            """)
            assert int(result) == 0, "seasonality_index should be >= 1 when present"
        finally:
            conn.close()

    def test_monthly_cv_null_when_insufficient_months(self):
        """Verify monthly_cv is NULL for products with fewer than 2 active months."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE months_active < 2 AND monthly_cv IS NOT NULL
            """)
            assert int(result) == 0, "monthly_cv should be NULL for months_active < 2"
        finally:
            conn.close()

    def test_monthly_trend_thresholds(self):
        """Verify Rapid Growth requires change >= 10 and Rapid Decline requires change <= -10."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE monthly_trend = 'Rapid Growth' AND month_velocity_change < 10
            """)
            assert int(result) == 0, "Rapid Growth requires month_velocity_change >= 10"

            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE monthly_trend = 'Rapid Decline' AND month_velocity_change > -10
            """)
            assert int(result) == 0, "Rapid Decline requires month_velocity_change <= -10"
        finally:
            conn.close()


class TestVelocityTrendLogic:
    """Tests for velocity trend classification logic."""

    def test_accelerating_threshold(self):
        """Verify Accelerating trend requires velocity_change_ratio > 1.25."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_trend = 'Accelerating' AND velocity_change_ratio <= 1.25
            """)
            assert int(result) == 0, f"Found Accelerating products with velocity_change_ratio <= 1.25"
        finally:
            conn.close()

    def test_declining_threshold(self):
        """Verify Declining trend requires velocity_change_ratio < 0.75."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_trend = 'Declining' AND velocity_change_ratio >= 0.75
            """)
            assert int(result) == 0, f"Found Declining products with velocity_change_ratio >= 0.75"
        finally:
            conn.close()

    def test_new_product_threshold(self):
        """Verify New Product trend requires NULL velocity_change_ratio and active_days < 30."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE velocity_trend = 'New Product' AND (velocity_change_ratio IS NOT NULL OR active_days >= 30)
            """)
            assert int(result) == 0, "New Product requires velocity_change_ratio NULL and active_days < 30"
        finally:
            conn.close()


class TestPerformanceScore:
    """Tests for performance score logic."""

    def test_performance_score_range(self):
        """Verify all performance_score values are within the 0-100 range."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE performance_score < 0 OR performance_score > 100
            """)
            assert int(result) == 0, "performance_score should be within 0-100"
        finally:
            conn.close()

    def test_performance_grade_thresholds(self):
        """Verify grade A requires score >= 80 and grade F requires score < 35."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE performance_grade = 'A' AND performance_score < 80
            """)
            assert int(result) == 0, "Grade A requires performance_score >= 80"

            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE performance_grade = 'F' AND performance_score >= 35
            """)
            assert int(result) == 0, "Grade F requires performance_score < 35"
        finally:
            conn.close()

    def test_performance_score_formula(self):
        """Verify performance_score follows the specified formula with revenue, velocity, consistency, and trend points."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                WITH total_products AS (
                    SELECT COUNT(*) AS n FROM {SCHEMA}.product_sales_velocity
                ),
                scored AS (
                    SELECT
                        p.*,
                        CAST(ROUND(
                            CASE
                                WHEN t.n = 1 THEN 35
                                ELSE 35.0 * (1.0 - (revenue_rank - 1) * 1.0 / NULLIF(t.n - 1, 0))
                            END
                        ) AS INTEGER) AS calc_revenue_points,
                        CASE velocity_tier
                            WHEN 'Elite' THEN 25
                            WHEN 'High' THEN 20
                            WHEN 'Medium' THEN 15
                            WHEN 'Low' THEN 8
                            ELSE 3
                        END AS calc_velocity_points,
                        CASE consistency_tier
                            WHEN 'Very Consistent' THEN 20
                            WHEN 'Consistent' THEN 16
                            WHEN 'Variable' THEN 10
                            WHEN 'Highly Variable' THEN 4
                            ELSE 10
                        END AS calc_consistency_points,
                        CASE monthly_trend
                            WHEN 'Rapid Growth' THEN 20
                            WHEN 'Growth' THEN 16
                            WHEN 'Stable' THEN 12
                            WHEN 'Decline' THEN 6
                            WHEN 'Rapid Decline' THEN 2
                            ELSE 10
                        END AS calc_trend_points
                    FROM {SCHEMA}.product_sales_velocity p
                    CROSS JOIN total_products t
                )
                SELECT COUNT(*) FROM scored
                WHERE performance_score != CAST(
                    GREATEST(0, LEAST(100, calc_revenue_points + calc_velocity_points + calc_consistency_points + calc_trend_points))
                    AS INTEGER
                )
            """)
            assert int(result) == 0, "performance_score must follow the specified formula"
        finally:
            conn.close()


class TestMomentumScore:
    """Tests for momentum score logic."""

    def test_momentum_score_formula(self):
        """Verify momentum_score follows the specified formula based on monthly_trend and velocity_trend."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE momentum_score != CAST(GREATEST(0, LEAST(100,
                    CASE monthly_trend
                        WHEN 'Rapid Growth' THEN 40
                        WHEN 'Growth' THEN 30
                        WHEN 'Stable' THEN 20
                        WHEN 'Decline' THEN 10
                        WHEN 'Rapid Decline' THEN 0
                        ELSE 15
                    END
                    +
                    CASE velocity_trend
                        WHEN 'Accelerating' THEN 30
                        WHEN 'Growing' THEN 20
                        WHEN 'Stable' THEN 15
                        WHEN 'Slowing' THEN 8
                        WHEN 'Declining' THEN 2
                        WHEN 'New Product' THEN 12
                        ELSE 10
                    END
                )) AS INTEGER)
            """)
            assert int(result) == 0, "momentum_score must follow the specified formula"
        finally:
            conn.close()

    def test_momentum_tier_thresholds(self):
        """Verify Hot tier requires score >= 60 and Cold tier requires score < 25."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE momentum_tier = 'Hot' AND momentum_score < 60
            """)
            assert int(result) == 0, "Hot tier requires momentum_score >= 60"

            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE momentum_tier = 'Cold' AND momentum_score >= 25
            """)
            assert int(result) == 0, "Cold tier requires momentum_score < 25"
        finally:
            conn.close()


class TestVolatilityBandLogic:
    """Tests for volatility band classification."""

    def test_insufficient_volatility(self):
        """Verify Insufficient volatility band requires both CVs to be NULL."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE volatility_band = 'Insufficient'
                  AND monthly_cv IS NOT NULL
                  AND velocity_cv IS NOT NULL
            """)
            assert int(result) == 0, "Insufficient requires both CVs NULL"
        finally:
            conn.close()

    def test_highly_volatile_threshold(self):
        """Verify Highly Volatile band requires CV >= 200."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE volatility_band = 'Highly Volatile'
                  AND COALESCE(monthly_cv, velocity_cv) < 200
            """)
            assert int(result) == 0, "Highly Volatile requires CV >= 200"
        finally:
            conn.close()

    def test_stable_threshold(self):
        """Verify Stable volatility band requires CV < 50."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE volatility_band = 'Stable'
                  AND COALESCE(monthly_cv, velocity_cv) >= 50
            """)
            assert int(result) == 0, "Stable requires CV < 50"
        finally:
            conn.close()


class TestDemandPatternLogic:
    """Tests for demand_pattern classification logic."""

    def test_breakout_conditions(self):
        """Verify Breakout demand requires Elite/High tier, Growth trend, and consistent sales."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE demand_pattern = 'Breakout'
                  AND NOT (
                    velocity_tier IN ('Elite', 'High')
                    AND monthly_trend IN ('Rapid Growth', 'Growth')
                    AND consistency_tier IN ('Very Consistent', 'Consistent')
                  )
            """)
            assert int(result) == 0, "Breakout must satisfy tier/trend/consistency conditions"
        finally:
            conn.close()

    def test_seasonal_conditions(self):
        """Verify Seasonal demand requires monthly_cv >= 150 and months_active >= 4."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE demand_pattern = 'Seasonal'
                  AND NOT (monthly_cv >= 150 AND months_active >= 4)
            """)
            assert int(result) == 0, "Seasonal must satisfy monthly_cv >= 150 and months_active >= 4"
        finally:
            conn.close()

    def test_new_entry_conditions(self):
        """Verify New Entry demand pattern requires monthly_trend = 'New'."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE demand_pattern = 'New Entry' AND monthly_trend != 'New'
            """)
            assert int(result) == 0, "New Entry requires monthly_trend = 'New'"
        finally:
            conn.close()


class TestHalfPeriodMetrics:
    """Tests for half-period velocity analysis."""

    def test_half_units_sum_equals_total(self):
        """Verify first_half_units + second_half_units equals total_units_sold."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE first_half_units + second_half_units != total_units_sold
            """)
            assert int(result) == 0, "Half units should sum to total_units_sold"
        finally:
            conn.close()

    def test_velocity_change_ratio_null_for_single_day(self):
        """Verify velocity_change_ratio is NULL for products with fewer than 2 active days."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE active_days < 2 AND velocity_change_ratio IS NOT NULL
            """)
            assert int(result) == 0, "Single-day products must have NULL velocity_change_ratio"
        finally:
            conn.close()


class TestRankings:
    """Tests for ranking columns."""

    def test_revenue_rank_starts_at_one(self):
        """Verify the minimum revenue_rank is 1."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT MIN(revenue_rank) FROM {SCHEMA}.product_sales_velocity
            """)
            assert int(result) == 1, f"Expected minimum revenue_rank to be 1, got {result}"
        finally:
            conn.close()

    def test_revenue_ranks_are_unique(self):
        """Verify all revenue_rank values are unique across products."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) - COUNT(DISTINCT revenue_rank)
                FROM {SCHEMA}.product_sales_velocity
            """)
            assert int(result) == 0, "revenue_rank values must be unique"
        finally:
            conn.close()

    def test_category_velocity_percentile_range(self):
        """Verify all category_velocity_percentile values are within the 1-100 range."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.product_sales_velocity
                WHERE category_velocity_percentile < 1 OR category_velocity_percentile > 100
            """)
            assert int(result) == 0, "category_velocity_percentile must be in 1-100"
        finally:
            conn.close()

    def test_category_velocity_rank_unique(self):
        """Verify category_velocity_rank is unique within each category."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT SUM(cnt - distinct_cnt) FROM (
                    SELECT category_id,
                           COUNT(*) AS cnt,
                           COUNT(DISTINCT category_velocity_rank) AS distinct_cnt
                    FROM {SCHEMA}.product_sales_velocity
                    GROUP BY category_id
                )
            """)
            assert int(result) == 0, "category_velocity_rank must be unique within category"
        finally:
            conn.close()
