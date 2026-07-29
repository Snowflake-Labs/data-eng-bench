"""
Test suite for POS Operations dimensional models.

This module tests the completeness and correctness of intermediate and mart models
for e-commerce order analytics.
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


MODEL_SCHEMA = "main"

# Define all expected models
INTERMEDIATE_MODELS = [
    "int_pos__order_daily_summary",
    "int_pos__order_timing",
    "int_pos__payment_summary",
    "int_pos__product_velocity",
    "int_pos__basket_metrics",
    "int_pos__order_status_summary",
    "int_pos__promotion_effectiveness",
    "int_pos__return_summary",
]

MART_MODELS = [
    "dim_order_sources",
    "fct_pos_orders",
    "fct_order_lines",
    "fct_order_daily_performance",
    "fct_payment_analysis",
    "fct_product_performance",
    "fct_order_fulfillment",
    "fct_return_analysis",
    "source_performance_scores",
    "fct_promotion_performance",
    "rpt_order_source_rankings",
    "bridge_order_product",
    "fct_order_patterns",
]

ALL_MODELS = INTERMEDIATE_MODELS + MART_MODELS

# Define required columns for each model
REQUIRED_COLUMNS = {
    "int_pos__order_daily_summary": [
        "order_source", "order_date", "order_count", "total_revenue",
        "total_items_sold", "avg_order_value", "avg_items_per_order"
    ],
    "int_pos__order_timing": [
        "order_id", "order_source", "order_type", "ordered_at", "shipped_at",
        "delivered_at", "cancelled_at", "order_to_ship_days", "ship_to_delivery_days",
        "total_fulfillment_days", "is_cancelled", "is_delivered"
    ],
    "int_pos__payment_summary": [
        "order_source", "payment_method", "transaction_count", "total_amount",
        "avg_transaction_amount", "payment_method_share"
    ],
    "int_pos__product_velocity": [
        "variant_id", "order_source", "units_sold", "units_returned",
        "total_revenue", "order_count", "avg_units_per_order", "days_with_sales",
        "velocity_score", "return_rate"
    ],
    "int_pos__basket_metrics": [
        "order_id", "basket_size", "total_units", "basket_value",
        "avg_item_price", "has_discount", "total_discount", "discount_rate"
    ],
    "int_pos__order_status_summary": [
        "order_source", "status", "payment_status", "fulfillment_status",
        "order_count", "total_revenue", "avg_order_value"
    ],
    "int_pos__promotion_effectiveness": [
        "promotion_id", "promotion_code", "promotion_name", "promotion_type",
        "discount_type", "orders_with_promotion", "total_discount_given",
        "total_revenue", "avg_order_value", "avg_discount_per_order"
    ],
    "int_pos__return_summary": [
        "order_source", "variant_id", "return_count", "total_units_returned",
        "total_units_sold", "return_rate", "return_value"
    ],
    "dim_order_sources": [
        "order_source", "order_count", "total_revenue", "first_order_date",
        "last_order_date", "is_active"
    ],
    "fct_pos_orders": [
        "order_id", "order_number", "customer_id", "order_type", "order_source",
        "currency_code", "subtotal", "discount_total", "shipping_total",
        "tax_total", "grand_total", "status", "payment_status",
        "fulfillment_status", "ordered_at", "shipped_at", "delivered_at",
        "cancelled_at", "order_to_ship_days", "is_delivered", "is_cancelled"
    ],
    "fct_order_lines": [
        "order_line_id", "order_id", "line_number", "variant_id", "sku",
        "product_name", "quantity_ordered", "quantity_shipped",
        "quantity_returned", "unit_price", "discount_amount", "tax_amount",
        "line_total", "status", "has_return"
    ],
    "fct_order_daily_performance": [
        "order_source", "order_date", "order_count", "total_revenue",
        "total_items_sold", "avg_order_value", "avg_basket_size",
        "cancelled_order_count", "cancellation_rate", "delivered_order_count",
        "delivery_rate", "avg_fulfillment_days"
    ],
    "fct_payment_analysis": [
        "order_source", "payment_method", "transaction_count", "total_amount",
        "avg_transaction_amount", "payment_method_share",
        "successful_payment_count", "success_rate"
    ],
    "fct_product_performance": [
        "variant_id", "sku", "product_name", "total_units_sold",
        "total_units_returned", "total_revenue", "total_orders",
        "avg_units_per_order", "return_rate", "velocity_score",
        "velocity_category"
    ],
    "fct_order_fulfillment": [
        "order_id", "order_source", "order_type", "ordered_at", "shipped_at",
        "delivered_at", "order_to_ship_days", "ship_to_delivery_days",
        "total_fulfillment_days", "is_delivered", "is_on_time",
        "fulfillment_tier"
    ],
    "fct_return_analysis": [
        "order_source", "variant_id", "product_name", "return_count",
        "total_units_returned", "total_units_sold", "return_rate",
        "return_value", "return_risk_level"
    ],
    "source_performance_scores": [
        "order_source", "total_orders", "total_revenue", "avg_order_value",
        "cancellation_rate", "delivery_rate", "performance_score",
        "performance_grade", "revenue_rank", "order_rank"
    ],
    "fct_promotion_performance": [
        "promotion_id", "promotion_code", "promotion_name", "promotion_type",
        "discount_type", "orders_with_promotion", "total_discount_given",
        "total_revenue", "avg_order_value", "avg_discount_per_order",
        "discount_to_revenue_ratio", "promotion_effectiveness"
    ],
    "rpt_order_source_rankings": [
        "order_source", "total_revenue", "total_orders", "avg_order_value",
        "cancellation_rate", "performance_score", "revenue_rank",
        "order_rank", "performance_rank", "is_top_performer",
        "is_underperformer"
    ],
    "bridge_order_product": [
        "order_id", "variant_id", "units_ordered", "units_returned",
        "line_revenue", "has_discount", "discount_amount"
    ],
    "fct_order_patterns": [
        "order_id", "order_source", "order_type", "ordered_at", "order_date",
        "order_hour", "day_of_week", "is_weekend", "basket_size",
        "basket_value", "payment_method", "is_high_value", "has_return"
    ],
}


def query_model(model_name, columns="*", where=None):
    """Helper function to query a model from the database."""
    conn, db_type = get_db_connection()
    try:
        sql = f"SELECT {columns} FROM {MODEL_SCHEMA}.{model_name}"
        if where:
            sql += f" WHERE {where}"
        return execute_query(conn, db_type, sql)
    finally:
        conn.close()


def get_column_names(model_name):
    """Get actual column names from the model."""
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {MODEL_SCHEMA}.{model_name} LIMIT 1")
            return [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute(f"SELECT * FROM {MODEL_SCHEMA}.{model_name} LIMIT 1")
            return [col[0].lower() for col in result.description]
    finally:
        conn.close()


def to_bool(val):
    """Convert a value to boolean, handling Snowflake integer booleans and DuckDB booleans."""
    if val is None:
        return None
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return val != 0
    s = str(val).upper()
    return s in ('TRUE', '1', 'T', 'YES', 'Y')


class TestModelExistence:
    """Test that all required models exist and have data."""

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_model_exists(self, model_name):
        """
        Test that each required model exists and has at least one row.
        """
        optional_data_models = {
            "int_pos__return_summary",
            "fct_return_analysis"
        }

        result = query_model(model_name, "COUNT(*)")
        count = int(result[0][0])

        if model_name in optional_data_models:
            assert count >= 0, f"Model {model_name} should exist"
        else:
            assert count > 0, f"Model {model_name} exists but has no data"

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_required_columns_exist(self, model_name):
        """
        Test that each model has all required columns.
        """
        actual_columns = get_column_names(model_name)
        required = [col.lower() for col in REQUIRED_COLUMNS[model_name]]
        missing = set(required) - set(actual_columns)
        assert not missing, f"Model {model_name} is missing columns: {missing}"


class TestIntermediateModels:
    """Test intermediate layer models for data quality."""

    def test_order_daily_summary_aggregation(self):
        """
        Verify order_daily_summary has correct aggregations.
        """
        result = query_model(
            "int_pos__order_daily_summary",
            "order_source, order_date, order_count"
        )
        assert len(result) > 0, "No data in order_daily_summary"
        for row in result:
            assert int(row[2]) > 0, "order_count should be positive"

    def test_order_timing_fulfillment_calculations(self):
        """
        Verify order timing calculations are correct.
        Allow a small fraction of negative values due to dirty source timestamps.
        """
        result = query_model(
            "int_pos__order_timing",
            "order_id, order_to_ship_days, total_fulfillment_days",
            "order_to_ship_days IS NOT NULL"
        )
        negative_count = sum(1 for row in result if int(row[1]) < 0)
        total_count = len(result)
        if total_count > 0:
            negative_pct = negative_count / total_count
            assert negative_pct < 0.10, (
                f"More than 10% of rows have negative order_to_ship_days: "
                f"{negative_count}/{total_count} ({negative_pct:.1%})"
            )

    def test_payment_summary_shares(self):
        """
        Verify payment method shares sum to ~1.0 per source.
        """
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT order_source, SUM(payment_method_share) as total_share
                FROM main.int_pos__payment_summary
                WHERE order_source IS NOT NULL
                GROUP BY order_source
            """)

            for row in result:
                if row[1] is not None:
                    share = float(row[1])
                    assert 0.99 <= share <= 1.01, f"Payment shares for {row[0]} should sum to 1.0, got {share}"
        finally:
            conn.close()

    def test_product_velocity_calculations(self):
        """
        Verify product velocity score calculations.
        """
        result = query_model(
            "int_pos__product_velocity",
            "variant_id, units_sold, days_with_sales, velocity_score",
            "velocity_score IS NOT NULL AND days_with_sales > 0"
        )
        for row in result[:10]:
            expected_velocity = float(row[1]) / float(row[2])
            actual_velocity = float(row[3])
            assert abs(actual_velocity - expected_velocity) < 0.01, \
                f"Velocity score mismatch for product {row[0]}"

    def test_basket_metrics_discount_rate(self):
        """
        Verify discount rate is in valid range [0, 1].
        """
        result = query_model(
            "int_pos__basket_metrics",
            "order_id, discount_rate",
            "discount_rate IS NOT NULL"
        )
        for row in result:
            rate = float(row[1])
            assert 0.0 <= rate <= 1.0, \
                f"Discount rate for order {row[0]} should be between 0 and 1, got {rate}"

    def test_return_summary_return_rate(self):
        """
        Verify return rate calculations are valid.
        """
        result = query_model(
            "int_pos__return_summary",
            "order_source, variant_id, total_units_returned, total_units_sold, return_rate",
            "return_rate IS NOT NULL"
        )
        for row in result[:10]:
            units_returned = float(row[2])
            units_sold = float(row[3])
            actual_rate = float(row[4])
            expected_rate = units_returned / units_sold if units_sold > 0 else None
            if expected_rate:
                assert abs(actual_rate - expected_rate) < 0.01, \
                    f"Return rate mismatch for {row[0]}/{row[1]}"


class TestMartModels:
    """Test mart layer models for business logic."""

    def test_dim_order_sources_uniqueness(self):
        """
        Verify dim_order_sources has unique order_source.
        """
        result = query_model(
            "dim_order_sources",
            "COUNT(*), COUNT(DISTINCT order_source)"
        )
        total, unique = int(result[0][0]), int(result[0][1])
        assert total == unique, "dim_order_sources should have unique order_source"

    def test_fct_pos_orders_primary_key(self):
        """
        Verify fct_pos_orders has unique order_id.
        """
        result = query_model(
            "fct_pos_orders",
            "COUNT(*), COUNT(DISTINCT order_id)"
        )
        total, unique = int(result[0][0]), int(result[0][1])
        assert total == unique, "fct_pos_orders should have unique order_id"

    def test_fct_order_lines_primary_key(self):
        """
        Verify fct_order_lines has unique order_line_id (excluding NULLs).
        """
        result = query_model(
            "fct_order_lines",
            "COUNT(*), COUNT(DISTINCT order_line_id)",
            "order_line_id IS NOT NULL"
        )
        total, unique = int(result[0][0]), int(result[0][1])
        assert total == unique, "fct_order_lines should have unique order_line_id (excluding NULLs)"

    def test_fct_order_daily_performance_rates(self):
        """
        Verify rates are in valid range [0, 1].
        """
        result = query_model(
            "fct_order_daily_performance",
            "order_source, order_date, cancellation_rate, delivery_rate",
            "cancellation_rate IS NOT NULL OR delivery_rate IS NOT NULL"
        )
        for row in result:
            if row[2] is not None:
                rate = float(row[2])
                assert 0.0 <= rate <= 1.0, \
                    f"Cancellation rate should be 0-1 for {row[0]}/{row[1]}, got {rate}"
            if row[3] is not None:
                rate = float(row[3])
                assert 0.0 <= rate <= 1.0, \
                    f"Delivery rate should be 0-1 for {row[0]}/{row[1]}, got {rate}"

    def test_fct_payment_analysis_success_rate(self):
        """
        Verify payment success rate is valid.
        """
        result = query_model(
            "fct_payment_analysis",
            "order_source, payment_method, success_rate",
            "success_rate IS NOT NULL"
        )
        for row in result:
            rate = float(row[2])
            assert 0.0 <= rate <= 1.0, \
                f"Success rate for {row[0]}/{row[1]} should be 0-1, got {rate}"

    def test_fct_product_performance_velocity_category(self):
        """
        Verify velocity_category values are valid.
        """
        result = query_model(
            "fct_product_performance",
            "variant_id, velocity_score, velocity_category",
            "velocity_category IS NOT NULL"
        )
        valid_categories = {'FAST', 'MEDIUM', 'SLOW'}
        for row in result[:20]:
            assert row[2] in valid_categories, \
                f"Invalid velocity_category for product {row[0]}: {row[2]}"

            vs = float(row[1]) if row[1] is not None else None
            if vs is not None and vs >= 5:
                assert row[2] == 'FAST', f"Product {row[0]} with velocity {vs} should be FAST"
            elif vs is not None and vs >= 1:
                assert row[2] == 'MEDIUM', f"Product {row[0]} with velocity {vs} should be MEDIUM"
            elif vs is not None and vs < 1:
                assert row[2] == 'SLOW', f"Product {row[0]} with velocity {vs} should be SLOW"

    def test_fct_order_fulfillment_tier_values(self):
        """
        Verify fulfillment_tier contains only valid values.
        """
        result = query_model(
            "fct_order_fulfillment",
            "DISTINCT fulfillment_tier"
        )
        valid_tiers = {'EXCELLENT', 'GOOD', 'ACCEPTABLE', 'SLOW'}
        actual_tiers = {row[0] for row in result if row[0] is not None}
        invalid = actual_tiers - valid_tiers
        assert not invalid, f"Found invalid fulfillment tiers: {invalid}"

    def test_fct_return_analysis_risk_level(self):
        """
        Verify return_risk_level contains only valid values.
        """
        result = query_model(
            "fct_return_analysis",
            "DISTINCT return_risk_level"
        )
        valid_levels = {'CRITICAL', 'HIGH', 'MEDIUM', 'LOW'}
        actual_levels = {row[0] for row in result if row[0] is not None}
        invalid = actual_levels - valid_levels
        assert not invalid, f"Found invalid return risk levels: {invalid}"

    def test_source_performance_scores_grade_values(self):
        """
        Verify performance_grade contains only valid values.
        """
        result = query_model(
            "source_performance_scores",
            "performance_score, performance_grade"
        )
        valid_grades = {'A', 'B', 'C', 'D', 'F'}
        for row in result:
            assert row[1] in valid_grades, f"Invalid grade: {row[1]}"

            score = float(row[0])
            if score >= 90:
                assert row[1] == 'A', f"Score {score} should be grade A"
            elif score >= 80:
                assert row[1] == 'B', f"Score {score} should be grade B"
            elif score >= 70:
                assert row[1] == 'C', f"Score {score} should be grade C"
            elif score >= 60:
                assert row[1] == 'D', f"Score {score} should be grade D"
            else:
                assert row[1] == 'F', f"Score {score} should be grade F"

    def test_source_performance_scores_score_range(self):
        """
        Verify performance_score is in range [0, 100].
        """
        result = query_model(
            "source_performance_scores",
            "order_source, performance_score"
        )
        for row in result:
            score = float(row[1])
            assert 0.0 <= score <= 100.0, \
                f"Performance score for {row[0]} should be 0-100, got {score}"

    def test_source_performance_scores_rankings(self):
        """
        Verify rankings start at 1 and have no gaps.
        """
        result = query_model(
            "source_performance_scores",
            "COUNT(*) as total, MIN(revenue_rank) as min_rank, MAX(revenue_rank) as max_rank"
        )
        total, min_rank, max_rank = int(result[0][0]), int(result[0][1]), int(result[0][2])
        assert min_rank == 1, "Revenue rank should start at 1"
        assert max_rank == total, "Revenue rank should have no gaps"

    def test_fct_promotion_performance_effectiveness(self):
        """
        Verify promotion_effectiveness contains only valid values.
        """
        result = query_model(
            "fct_promotion_performance",
            "DISTINCT promotion_effectiveness"
        )
        valid_values = {'EXCELLENT', 'GOOD', 'FAIR', 'POOR'}
        actual_values = {row[0] for row in result if row[0] is not None}
        invalid = actual_values - valid_values
        assert not invalid, f"Found invalid promotion effectiveness values: {invalid}"

    def test_rpt_order_source_rankings_top_performer(self):
        """
        Verify is_top_performer is TRUE only for performance_rank <= 3.
        """
        result = query_model(
            "rpt_order_source_rankings",
            "order_source, performance_rank, is_top_performer"
        )
        for row in result:
            rank = int(row[1])
            is_top = to_bool(row[2])
            if rank <= 3:
                assert is_top == True, f"Source {row[0]} with rank {rank} should be top performer"
            else:
                assert is_top == False, f"Source {row[0]} with rank {rank} should not be top performer"

    def test_rpt_order_source_rankings_underperformer(self):
        """
        Verify is_underperformer is TRUE for bottom 25%.
        """
        result = query_model(
            "rpt_order_source_rankings",
            "COUNT(*) as total"
        )
        total_sources = int(result[0][0])
        threshold = total_sources * 0.75

        result = query_model(
            "rpt_order_source_rankings",
            "order_source, performance_rank, is_underperformer"
        )
        for row in result:
            rank = int(row[1])
            is_under = to_bool(row[2])
            if rank > threshold:
                assert is_under == True, \
                    f"Source {row[0]} with rank {rank} should be underperformer (threshold: {threshold})"
            else:
                assert is_under == False, \
                    f"Source {row[0]} with rank {rank} should not be underperformer"

    def test_bridge_order_product_uniqueness(self):
        """
        Verify bridge_order_product has unique (order_id, variant_id) combinations.
        """
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT COUNT(*), COUNT(DISTINCT CONCAT(CAST(order_id AS VARCHAR), '-', CAST(variant_id AS VARCHAR)))
                FROM main.bridge_order_product
            """)
            total, unique = int(result[0][0]), int(result[0][1])
            assert total == unique, "bridge_order_product should have unique order-product pairs"
        finally:
            conn.close()

    def test_fct_order_patterns_day_of_week_values(self):
        """
        Verify day_of_week contains only valid day names.
        """
        result = query_model(
            "fct_order_patterns",
            "DISTINCT day_of_week"
        )
        valid_days = {'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'}
        actual_days = {row[0] for row in result if row[0] is not None}
        invalid = actual_days - valid_days
        assert not invalid, f"Found invalid day names: {invalid}"

    def test_fct_order_patterns_is_weekend_logic(self):
        """
        Verify is_weekend is TRUE only for Saturday/Sunday.
        """
        result = query_model(
            "fct_order_patterns",
            "day_of_week, is_weekend",
            "day_of_week IS NOT NULL"
        )
        for row in result[:50]:
            is_wknd = to_bool(row[1])
            if row[0] in ('Saturday', 'Sunday'):
                assert is_wknd == True, f"{row[0]} should be weekend"
            else:
                assert is_wknd == False, f"{row[0]} should not be weekend"

    def test_fct_order_patterns_order_hour_range(self):
        """
        Verify order_hour is in valid range [0-23].
        """
        result = query_model(
            "fct_order_patterns",
            "MIN(order_hour) as min_hour, MAX(order_hour) as max_hour",
            "order_hour IS NOT NULL"
        )
        min_hour, max_hour = int(result[0][0]), int(result[0][1])
        assert 0 <= min_hour, "Minimum hour should be >= 0"
        assert max_hour <= 23, "Maximum hour should be <= 23"


class TestDataIntegrity:
    """Test data integrity and relationships across models."""

    def test_order_count_consistency(self):
        """
        Verify order counts are consistent between fct_pos_orders and aggregated models.
        """
        orders_count = int(query_model("fct_pos_orders", "COUNT(*)")[0][0])
        daily_sum = int(query_model(
            "fct_order_daily_performance",
            "SUM(order_count)"
        )[0][0])

        assert abs(orders_count - daily_sum) / orders_count < 0.1, \
            f"Order count mismatch: fct_pos_orders={orders_count}, daily_sum={daily_sum}"

    def test_revenue_consistency(self):
        """
        Verify revenue totals are consistent across models.
        """
        orders_revenue = query_model(
            "fct_pos_orders",
            "SUM(grand_total)",
            "grand_total IS NOT NULL"
        )[0][0]

        daily_revenue = query_model(
            "fct_order_daily_performance",
            "SUM(total_revenue)"
        )[0][0]

        if orders_revenue and daily_revenue:
            orders_rev = float(orders_revenue)
            daily_rev = float(daily_revenue)
            diff_pct = abs(orders_rev - daily_rev) / orders_rev
            assert diff_pct < 0.01, \
                f"Revenue mismatch: orders={orders_rev}, daily={daily_rev}"

    def test_no_null_primary_keys(self):
        """
        Verify primary keys are not NULL.
        """
        result = query_model("fct_pos_orders", "COUNT(*)", "order_id IS NULL")
        assert int(result[0][0]) == 0, "fct_pos_orders should have no NULL order_id"

        result = query_model("fct_order_lines", "COUNT(*)", "order_line_id IS NULL")
        assert int(result[0][0]) == 0, "fct_order_lines should have no NULL order_line_id"

        result = query_model("dim_order_sources", "COUNT(*)", "order_source IS NULL")
        assert int(result[0][0]) == 0, "dim_order_sources should have no NULL order_source"
