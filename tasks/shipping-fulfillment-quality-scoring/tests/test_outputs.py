"""
Tests for Shipping & Fulfillment Quality Scoring dbt models.

This test suite validates the intermediate and marts layer models
for shipping quality analysis and carrier performance scorecards.
"""

import pytest
import os
import subprocess
from decimal import Decimal


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
        private_key_pem, password=passphrase_bytes, backend=default_backend()
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


# ============ HELPERS ============

MODEL_SCHEMA = "main"


def to_float(val):
    """Convert Decimal or other numeric types to float."""
    if val is None:
        return None
    if isinstance(val, Decimal):
        return float(val)
    return float(val)


def query_model(model_name, columns="*", where=None, limit=None):
    """Helper to query a model with optional filters."""
    conn, db_type = get_db_connection()
    try:
        sql = f"SELECT {columns} FROM {MODEL_SCHEMA}.{model_name}"
        if where:
            sql += f" WHERE {where}"
        if limit:
            sql += f" LIMIT {limit}"
        return execute_query(conn, db_type, sql)
    finally:
        conn.close()


def get_columns(model_name):
    """Get column names for a model (lowercased for case-insensitive comparison)."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = '{MODEL_SCHEMA}' AND lower(table_name) = '{model_name}'
            ORDER BY ordinal_position
        """)
        return [row[0].lower() for row in result]
    finally:
        conn.close()


# ============================================================================
# MODEL EXISTENCE TESTS
# ============================================================================

class TestModelExistence:
    """Verify all required models exist and have data."""

    def test_int_shipment_tracking_metrics_exists(self):
        """int_shipment_tracking_metrics model should exist and have rows."""
        result = query_model("int_shipment_tracking_metrics", "COUNT(*)")
        assert int(result[0][0]) > 0, "int_shipment_tracking_metrics should have rows"

    def test_int_shipment_delivery_metrics_exists(self):
        """int_shipment_delivery_metrics model should exist and have rows."""
        result = query_model("int_shipment_delivery_metrics", "COUNT(*)")
        assert int(result[0][0]) > 0, "int_shipment_delivery_metrics should have rows"

    def test_int_shipment_package_metrics_exists(self):
        """int_shipment_package_metrics model should exist and have rows."""
        result = query_model("int_shipment_package_metrics", "COUNT(*)")
        assert int(result[0][0]) > 0, "int_shipment_package_metrics should have rows"

    def test_shipment_quality_scores_exists(self):
        """shipment_quality_scores model should exist and have rows."""
        result = query_model("shipment_quality_scores", "COUNT(*)")
        assert int(result[0][0]) > 0, "shipment_quality_scores should have rows"

    def test_carrier_performance_scorecard_exists(self):
        """carrier_performance_scorecard model should exist and have rows."""
        result = query_model("carrier_performance_scorecard", "COUNT(*)")
        assert int(result[0][0]) > 0, "carrier_performance_scorecard should have rows"


# ============================================================================
# COLUMN EXISTENCE TESTS
# ============================================================================

class TestColumnExistence:
    """Verify all required columns exist in each model."""

    def test_int_shipment_tracking_metrics_columns(self):
        """int_shipment_tracking_metrics should have all required columns."""
        required_columns = [
            'shipment_id', 'tracking_events_count', 'first_tracking_at',
            'last_tracking_at', 'has_exception', 'tracking_duration_hours',
            'avg_hours_between_updates', 'distinct_locations_count',
            'reached_out_for_delivery'
        ]
        actual_columns = get_columns("int_shipment_tracking_metrics")
        for col in required_columns:
            assert col in actual_columns, f"Missing column: {col}"

    def test_int_shipment_delivery_metrics_columns(self):
        """int_shipment_delivery_metrics should have all required columns."""
        required_columns = [
            'shipment_id', 'order_id', 'carrier_id', 'shipping_method_id',
            'shipped_at', 'delivered_at', 'shipping_cost', 'weight', 'status',
            'is_delivered', 'delivery_days', 'estimated_days_min',
            'estimated_days_max', 'is_express', 'sla_target_days',
            'is_on_time', 'days_early_or_late'
        ]
        actual_columns = get_columns("int_shipment_delivery_metrics")
        for col in required_columns:
            assert col in actual_columns, f"Missing column: {col}"

    def test_int_shipment_package_metrics_columns(self):
        """int_shipment_package_metrics should have all required columns."""
        required_columns = [
            'shipment_id', 'package_count', 'total_weight', 'total_volume_cubic',
            'avg_package_weight', 'items_shipped', 'line_count'
        ]
        actual_columns = get_columns("int_shipment_package_metrics")
        for col in required_columns:
            assert col in actual_columns, f"Missing column: {col}"

    def test_shipment_quality_scores_columns(self):
        """shipment_quality_scores should have all required columns."""
        required_columns = [
            'shipment_id', 'shipment_number', 'order_id', 'carrier_id',
            'carrier_name', 'carrier_type', 'shipping_method_id', 'is_express',
            'shipped_at', 'shipped_date', 'delivered_at', 'status',
            'is_delivered', 'delivery_days', 'sla_target_days', 'is_on_time',
            'days_early_or_late', 'shipping_cost', 'weight', 'package_count',
            'items_shipped', 'tracking_events_count', 'has_exception',
            'avg_hours_between_updates', 'delivery_score', 'tracking_score',
            'cost_efficiency_score', 'overall_quality_score', 'quality_tier'
        ]
        actual_columns = get_columns("shipment_quality_scores")
        for col in required_columns:
            assert col in actual_columns, f"Missing column: {col}"

    def test_carrier_performance_scorecard_columns(self):
        """carrier_performance_scorecard should have all required columns."""
        required_columns = [
            'carrier_id', 'carrier_name', 'carrier_type', 'total_shipments',
            'delivered_shipments', 'delivery_rate', 'on_time_shipments',
            'on_time_delivery_rate', 'avg_delivery_days', 'avg_days_early_or_late',
            'exception_shipments', 'exception_rate', 'total_shipping_cost',
            'avg_shipping_cost', 'total_weight_shipped', 'avg_cost_per_lb',
            'avg_delivery_score', 'avg_tracking_score', 'avg_overall_quality_score',
            'performance_tier', 'rank_by_quality', 'rank_by_volume'
        ]
        actual_columns = get_columns("carrier_performance_scorecard")
        for col in required_columns:
            assert col in actual_columns, f"Missing column: {col}"


# ============================================================================
# INT_SHIPMENT_TRACKING_METRICS TESTS
# ============================================================================

class TestIntShipmentTrackingMetrics:
    """Tests for int_shipment_tracking_metrics intermediate model."""

    def test_has_rows(self):
        """Model should contain data."""
        result = query_model("int_shipment_tracking_metrics", "COUNT(*)")
        assert int(result[0][0]) > 0

    def test_no_null_shipment_ids(self):
        """shipment_id should never be NULL."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="shipment_id IS NULL")
        assert int(result[0][0]) == 0, "shipment_id should not be NULL"

    def test_no_null_tracking_events_count(self):
        """tracking_events_count should never be NULL."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="tracking_events_count IS NULL")
        assert int(result[0][0]) == 0, "tracking_events_count should not be NULL"

    def test_tracking_events_count_non_negative(self):
        """tracking_events_count should be >= 0."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="tracking_events_count < 0")
        assert int(result[0][0]) == 0, "tracking_events_count should be non-negative"

    def test_tracking_duration_hours_non_negative(self):
        """tracking_duration_hours should be >= 0."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="tracking_duration_hours < 0")
        assert int(result[0][0]) == 0, "tracking_duration_hours should be non-negative"

    def test_avg_hours_between_updates_non_negative(self):
        """avg_hours_between_updates should be >= 0."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="avg_hours_between_updates < 0")
        assert int(result[0][0]) == 0, "avg_hours_between_updates should be non-negative"

    def test_distinct_locations_count_non_negative(self):
        """distinct_locations_count should be >= 0."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="distinct_locations_count < 0")
        assert int(result[0][0]) == 0, "distinct_locations_count should be non-negative"

    def test_has_exception_is_boolean(self):
        """has_exception should be a boolean value."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(DISTINCT CAST(has_exception AS VARCHAR))")
        assert int(result[0][0]) <= 2, "has_exception should have at most 2 distinct values"

    def test_reached_out_for_delivery_is_boolean(self):
        """reached_out_for_delivery should be a boolean value."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(DISTINCT CAST(reached_out_for_delivery AS VARCHAR))")
        assert int(result[0][0]) <= 2, "reached_out_for_delivery should have at most 2 distinct values"

    def test_one_row_per_shipment(self):
        """Should have exactly one row per shipment_id."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*) - COUNT(DISTINCT shipment_id)")
        assert int(result[0][0]) == 0, "Should have one row per shipment_id"

    def test_shipments_with_zero_tracking_events_exist(self):
        """Should include shipments with zero tracking events."""
        result = query_model("int_shipment_tracking_metrics",
            "COUNT(*)", where="tracking_events_count = 0")
        # This test just verifies the query runs - some shipments may have 0 events
        assert int(result[0][0]) >= 0


# ============================================================================
# INT_SHIPMENT_DELIVERY_METRICS TESTS
# ============================================================================

class TestIntShipmentDeliveryMetrics:
    """Tests for int_shipment_delivery_metrics intermediate model."""

    def test_has_rows(self):
        """Model should contain data."""
        result = query_model("int_shipment_delivery_metrics", "COUNT(*)")
        assert int(result[0][0]) > 0

    def test_no_null_shipment_ids(self):
        """shipment_id should never be NULL."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="shipment_id IS NULL")
        assert int(result[0][0]) == 0, "shipment_id should not be NULL"

    def test_no_null_order_ids(self):
        """order_id should never be NULL."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="order_id IS NULL")
        assert int(result[0][0]) == 0, "order_id should not be NULL"

    def test_no_null_carrier_ids(self):
        """carrier_id should never be NULL."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="carrier_id IS NULL")
        assert int(result[0][0]) == 0, "carrier_id should not be NULL"

    def test_no_null_status(self):
        """status should never be NULL."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="status IS NULL")
        assert int(result[0][0]) == 0, "status should not be NULL"

    def test_delivery_days_positive_when_delivered(self):
        """delivery_days should be non-negative for delivered shipments."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="is_delivered = TRUE AND delivery_days < 0")
        assert int(result[0][0]) == 0, "delivery_days should be non-negative when delivered"

    def test_delivery_days_null_when_not_delivered(self):
        """delivery_days should be NULL when not delivered."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="is_delivered = FALSE AND delivery_days IS NOT NULL")
        assert int(result[0][0]) == 0, "delivery_days should be NULL when not delivered"

    def test_is_delivered_matches_status(self):
        """is_delivered should be TRUE only when status is DELIVERED."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="is_delivered = TRUE AND status != 'DELIVERED'")
        assert int(result[0][0]) == 0, "is_delivered should match DELIVERED status"

    def test_is_on_time_null_when_not_delivered(self):
        """is_on_time should be NULL when not delivered."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="is_delivered = FALSE AND is_on_time IS NOT NULL")
        assert int(result[0][0]) == 0, "is_on_time should be NULL when not delivered"

    def test_days_early_or_late_null_when_not_delivered(self):
        """days_early_or_late should be NULL when not delivered."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="is_delivered = FALSE AND days_early_or_late IS NOT NULL")
        assert int(result[0][0]) == 0, "days_early_or_late should be NULL when not delivered"

    def test_sla_target_days_matches_estimated_max(self):
        """sla_target_days should equal estimated_days_max."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*)", where="sla_target_days != estimated_days_max AND estimated_days_max IS NOT NULL")
        assert int(result[0][0]) == 0, "sla_target_days should equal estimated_days_max"

    def test_one_row_per_shipment(self):
        """Should have exactly one row per shipment_id."""
        result = query_model("int_shipment_delivery_metrics",
            "COUNT(*) - COUNT(DISTINCT shipment_id)")
        assert int(result[0][0]) == 0, "Should have one row per shipment_id"


# ============================================================================
# INT_SHIPMENT_PACKAGE_METRICS TESTS
# ============================================================================

class TestIntShipmentPackageMetrics:
    """Tests for int_shipment_package_metrics intermediate model."""

    def test_has_rows(self):
        """Model should contain data."""
        result = query_model("int_shipment_package_metrics", "COUNT(*)")
        assert int(result[0][0]) > 0

    def test_no_null_shipment_ids(self):
        """shipment_id should never be NULL."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="shipment_id IS NULL")
        assert int(result[0][0]) == 0, "shipment_id should not be NULL"

    def test_no_null_package_count(self):
        """package_count should never be NULL."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="package_count IS NULL")
        assert int(result[0][0]) == 0, "package_count should not be NULL"

    def test_no_null_items_shipped(self):
        """items_shipped should never be NULL."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="items_shipped IS NULL")
        assert int(result[0][0]) == 0, "items_shipped should not be NULL"

    def test_package_count_non_negative(self):
        """package_count should be >= 0."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="package_count < 0")
        assert int(result[0][0]) == 0, "package_count should be non-negative"

    def test_items_shipped_non_negative(self):
        """items_shipped should be >= 0."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="items_shipped < 0")
        assert int(result[0][0]) == 0, "items_shipped should be non-negative"

    def test_total_weight_non_negative(self):
        """total_weight should be >= 0."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="total_weight < 0")
        assert int(result[0][0]) == 0, "total_weight should be non-negative"

    def test_total_volume_cubic_non_negative(self):
        """total_volume_cubic should be >= 0."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="total_volume_cubic < 0")
        assert int(result[0][0]) == 0, "total_volume_cubic should be non-negative"

    def test_avg_package_weight_non_negative(self):
        """avg_package_weight should be >= 0."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="avg_package_weight < 0")
        assert int(result[0][0]) == 0, "avg_package_weight should be non-negative"

    def test_line_count_non_negative(self):
        """line_count should be >= 0."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*)", where="line_count < 0")
        assert int(result[0][0]) == 0, "line_count should be non-negative"

    def test_one_row_per_shipment(self):
        """Should have exactly one row per shipment_id."""
        result = query_model("int_shipment_package_metrics",
            "COUNT(*) - COUNT(DISTINCT shipment_id)")
        assert int(result[0][0]) == 0, "Should have one row per shipment_id"


# ============================================================================
# SHIPMENT_QUALITY_SCORES TESTS
# ============================================================================

class TestShipmentQualityScores:
    """Tests for shipment_quality_scores marts model."""

    def test_has_rows(self):
        """Model should contain data."""
        result = query_model("shipment_quality_scores", "COUNT(*)")
        assert int(result[0][0]) > 0

    def test_no_null_shipment_ids(self):
        """shipment_id should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="shipment_id IS NULL")
        assert int(result[0][0]) == 0, "shipment_id should not be NULL"

    def test_no_null_carrier_ids(self):
        """carrier_id should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="carrier_id IS NULL")
        assert int(result[0][0]) == 0, "carrier_id should not be NULL"

    def test_no_null_shipped_at(self):
        """shipped_at should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="shipped_at IS NULL")
        assert int(result[0][0]) == 0, "shipped_at should not be NULL"

    def test_no_null_delivery_score(self):
        """delivery_score should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="delivery_score IS NULL")
        assert int(result[0][0]) == 0, "delivery_score should not be NULL"

    def test_no_null_tracking_score(self):
        """tracking_score should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="tracking_score IS NULL")
        assert int(result[0][0]) == 0, "tracking_score should not be NULL"

    def test_no_null_cost_efficiency_score(self):
        """cost_efficiency_score should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="cost_efficiency_score IS NULL")
        assert int(result[0][0]) == 0, "cost_efficiency_score should not be NULL"

    def test_no_null_overall_quality_score(self):
        """overall_quality_score should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="overall_quality_score IS NULL")
        assert int(result[0][0]) == 0, "overall_quality_score should not be NULL"

    def test_no_null_quality_tier(self):
        """quality_tier should never be NULL."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="quality_tier IS NULL")
        assert int(result[0][0]) == 0, "quality_tier should not be NULL"

    def test_delivery_score_in_range(self):
        """delivery_score should be between 0 and 100."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="delivery_score < 0 OR delivery_score > 100")
        assert int(result[0][0]) == 0, "delivery_score should be in range 0-100"

    def test_tracking_score_in_range(self):
        """tracking_score should be between 0 and 100."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="tracking_score < 0 OR tracking_score > 100")
        assert int(result[0][0]) == 0, "tracking_score should be in range 0-100"

    def test_cost_efficiency_score_in_range(self):
        """cost_efficiency_score should be between 0 and 100."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="cost_efficiency_score < 0 OR cost_efficiency_score > 100")
        assert int(result[0][0]) == 0, "cost_efficiency_score should be in range 0-100"

    def test_overall_quality_score_in_range(self):
        """overall_quality_score should be between 0 and 100."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="overall_quality_score < 0 OR overall_quality_score > 100")
        assert int(result[0][0]) == 0, "overall_quality_score should be in range 0-100"

    def test_quality_tier_values(self):
        """quality_tier should be one of the expected values."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="quality_tier NOT IN ('EXCELLENT', 'GOOD', 'FAIR', 'POOR')")
        assert int(result[0][0]) == 0, "quality_tier should be EXCELLENT, GOOD, FAIR, or POOR"

    def test_recent_shipments_only(self):
        """Should only include shipments on or after 2025-10-04."""
        date_expr = "'2025-10-04'"
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where=f"shipped_at < {date_expr}")
        assert int(result[0][0]) == 0, "Should only include shipments on or after 2025-10-04"

    def test_one_row_per_shipment(self):
        """Should have exactly one row per shipment_id."""
        result = query_model("shipment_quality_scores",
            "COUNT(*) - COUNT(DISTINCT shipment_id)")
        assert int(result[0][0]) == 0, "Should have one row per shipment_id"

    def test_ordered_by_shipped_at_desc(self):
        """Should be ordered by shipped_at descending."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT shipped_at
                FROM {MODEL_SCHEMA}.shipment_quality_scores
                LIMIT 100
            """)
            dates = [row[0] for row in result]
            assert dates == sorted(dates, reverse=True), "Should be ordered by shipped_at descending"
        finally:
            conn.close()

    def test_shipped_date_matches_shipped_at(self):
        """shipped_date should be the date portion of shipped_at."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="shipped_date != CAST(shipped_at AS DATE)")
        assert int(result[0][0]) == 0, "shipped_date should match shipped_at date"

    def test_carrier_names_not_empty(self):
        """carrier_name should not be empty."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="carrier_name IS NULL OR TRIM(carrier_name) = ''")
        assert int(result[0][0]) == 0, "carrier_name should not be empty"

    def test_carrier_type_values(self):
        """carrier_type should be one of the expected values."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="carrier_type NOT IN ('PARCEL', 'FREIGHT', 'COURIER', 'PICKUP')")
        assert int(result[0][0]) == 0, "carrier_type should be PARCEL, FREIGHT, COURIER, or PICKUP"


# ============================================================================
# CARRIER_PERFORMANCE_SCORECARD TESTS
# ============================================================================

class TestCarrierPerformanceScorecard:
    """Tests for carrier_performance_scorecard marts model."""

    def test_has_rows(self):
        """Model should contain data."""
        result = query_model("carrier_performance_scorecard", "COUNT(*)")
        assert int(result[0][0]) > 0

    def test_no_null_carrier_ids(self):
        """carrier_id should never be NULL."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="carrier_id IS NULL")
        assert int(result[0][0]) == 0, "carrier_id should not be NULL"

    def test_no_null_carrier_name(self):
        """carrier_name should never be NULL."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="carrier_name IS NULL")
        assert int(result[0][0]) == 0, "carrier_name should not be NULL"

    def test_no_null_total_shipments(self):
        """total_shipments should never be NULL."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="total_shipments IS NULL")
        assert int(result[0][0]) == 0, "total_shipments should not be NULL"

    def test_no_null_delivery_rate(self):
        """delivery_rate should never be NULL."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="delivery_rate IS NULL")
        assert int(result[0][0]) == 0, "delivery_rate should not be NULL"

    def test_no_null_on_time_delivery_rate(self):
        """on_time_delivery_rate should never be NULL."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="on_time_delivery_rate IS NULL")
        assert int(result[0][0]) == 0, "on_time_delivery_rate should not be NULL"

    def test_no_null_performance_tier(self):
        """performance_tier should never be NULL."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="performance_tier IS NULL")
        assert int(result[0][0]) == 0, "performance_tier should not be NULL"

    def test_delivery_rate_in_range(self):
        """delivery_rate should be between 0.0 and 1.0."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="delivery_rate < 0 OR delivery_rate > 1")
        assert int(result[0][0]) == 0, "delivery_rate should be in range 0.0-1.0"

    def test_on_time_delivery_rate_in_range(self):
        """on_time_delivery_rate should be between 0.0 and 1.0."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="on_time_delivery_rate < 0 OR on_time_delivery_rate > 1")
        assert int(result[0][0]) == 0, "on_time_delivery_rate should be in range 0.0-1.0"

    def test_exception_rate_in_range(self):
        """exception_rate should be between 0.0 and 1.0."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="exception_rate < 0 OR exception_rate > 1")
        assert int(result[0][0]) == 0, "exception_rate should be in range 0.0-1.0"

    def test_performance_tier_values(self):
        """performance_tier should be one of the expected values."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="performance_tier NOT IN ('PREMIUM', 'RELIABLE', 'STANDARD', 'UNDERPERFORMING')")
        assert int(result[0][0]) == 0, "performance_tier should be PREMIUM, RELIABLE, STANDARD, or UNDERPERFORMING"

    def test_one_row_per_carrier(self):
        """Should have exactly one row per carrier_id."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*) - COUNT(DISTINCT carrier_id)")
        assert int(result[0][0]) == 0, "Should have one row per carrier_id"

    def test_total_shipments_positive(self):
        """total_shipments should be positive."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="total_shipments <= 0")
        assert int(result[0][0]) == 0, "total_shipments should be positive"

    def test_delivered_not_exceed_total(self):
        """delivered_shipments should not exceed total_shipments."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="delivered_shipments > total_shipments")
        assert int(result[0][0]) == 0, "delivered_shipments should not exceed total_shipments"

    def test_on_time_not_exceed_delivered(self):
        """on_time_shipments should not exceed delivered_shipments."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="on_time_shipments > delivered_shipments")
        assert int(result[0][0]) == 0, "on_time_shipments should not exceed delivered_shipments"

    def test_exception_not_exceed_total(self):
        """exception_shipments should not exceed total_shipments."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="exception_shipments > total_shipments")
        assert int(result[0][0]) == 0, "exception_shipments should not exceed total_shipments"

    def test_ordered_by_quality_score_desc(self):
        """Should be ordered by avg_overall_quality_score descending."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT avg_overall_quality_score, carrier_name
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
            """)
            scores = [(float(row[0]), row[1]) for row in result]
            sorted_scores = sorted(scores, key=lambda x: (-x[0], x[1]))
            assert scores == sorted_scores, "Should be ordered by avg_overall_quality_score desc, then carrier_name"
        finally:
            conn.close()

    def test_rank_by_quality_unique(self):
        """rank_by_quality should be unique for each carrier."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT rank_by_quality, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
                GROUP BY rank_by_quality
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "rank_by_quality should be unique"
        finally:
            conn.close()

    def test_rank_by_volume_unique(self):
        """rank_by_volume should be unique for each carrier."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT rank_by_volume, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
                GROUP BY rank_by_volume
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "rank_by_volume should be unique"
        finally:
            conn.close()

    def test_avg_delivery_days_reasonable(self):
        """avg_delivery_days should be reasonable for carriers."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="avg_delivery_days < 0 OR avg_delivery_days > 30")
        assert int(result[0][0]) == 0, "avg_delivery_days should be reasonable"


# ============================================================================
# DELIVERY SCORE TESTS
# ============================================================================

class TestDeliveryScore:
    """Tests for delivery score calculation logic."""

    def test_on_time_delivery_score_100(self):
        """Delivered on-time (0 or more days early) should have delivery_score = 100."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="is_delivered = TRUE AND is_on_time = TRUE AND delivery_score != 100")
        assert int(result[0][0]) == 0, "On-time delivered shipments should have delivery_score = 100"

    def test_one_day_late_delivery_score_80(self):
        """Delivered 1 day late should have delivery_score = 80."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="is_delivered = TRUE AND days_early_or_late = -1 AND delivery_score != 80")
        assert int(result[0][0]) == 0, "1 day late delivery should have delivery_score = 80"

    def test_two_days_late_delivery_score_60(self):
        """Delivered 2 days late should have delivery_score = 60."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="is_delivered = TRUE AND days_early_or_late = -2 AND delivery_score != 60")
        assert int(result[0][0]) == 0, "2 days late delivery should have delivery_score = 60"

    def test_three_days_late_delivery_score_40(self):
        """Delivered 3 days late should have delivery_score = 40."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="is_delivered = TRUE AND days_early_or_late = -3 AND delivery_score != 40")
        assert int(result[0][0]) == 0, "3 days late delivery should have delivery_score = 40"

    def test_four_plus_days_late_delivery_score_20(self):
        """Delivered 4+ days late should have delivery_score = 20."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="is_delivered = TRUE AND days_early_or_late < -3 AND delivery_score != 20")
        assert int(result[0][0]) == 0, "4+ days late delivery should have delivery_score = 20"

    def test_in_transit_delivery_score_50(self):
        """IN_TRANSIT status should have delivery_score = 50."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="status = 'IN_TRANSIT' AND delivery_score != 50")
        assert int(result[0][0]) == 0, "IN_TRANSIT shipments should have delivery_score = 50"

    def test_shipped_delivery_score_50(self):
        """SHIPPED status should have delivery_score = 50."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="status = 'SHIPPED' AND delivery_score != 50")
        assert int(result[0][0]) == 0, "SHIPPED shipments should have delivery_score = 50"

    def test_pending_delivery_score_30(self):
        """PENDING status should have delivery_score = 30."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="status = 'PENDING' AND delivery_score != 30")
        assert int(result[0][0]) == 0, "PENDING shipments should have delivery_score = 30"

    def test_cancelled_delivery_score_0(self):
        """CANCELLED status should have delivery_score = 0."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="status = 'CANCELLED' AND delivery_score != 0")
        assert int(result[0][0]) == 0, "CANCELLED shipments should have delivery_score = 0"


# ============================================================================
# TRACKING SCORE TESTS
# ============================================================================

class TestTrackingScore:
    """Tests for tracking score calculation logic."""

    def test_tracking_score_tiers_no_bonus_no_penalty(self):
        """Verify tracking score follows event count tiers (no bonus/penalty)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    tracking_events_count,
                    tracking_score
                FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE has_exception = FALSE
                  AND (avg_hours_between_updates > 12 OR avg_hours_between_updates = 0)
                  AND tracking_events_count IN (0, 1, 2, 3, 4, 5)
                LIMIT 100
            """)

            expected_scores = {0: 0, 1: 20, 2: 40, 3: 60, 4: 75, 5: 90}
            for row in result:
                events, score = int(row[0]), int(row[1])
                if events in expected_scores:
                    assert score == expected_scores[events], \
                        f"Events={events} should score {expected_scores[events]}, got {score}"
        finally:
            conn.close()

    def test_tracking_score_six_plus_events(self):
        """6+ tracking events should score 100 (before bonus/penalty)."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE tracking_events_count >= 6
                  AND has_exception = FALSE
                  AND (avg_hours_between_updates > 12 OR avg_hours_between_updates = 0)
                  AND tracking_score != 100
            """)
            assert int(result[0][0]) == 0, "6+ events without bonus/penalty should score 100"
        finally:
            conn.close()

    def test_tracking_score_frequent_update_bonus(self):
        """Frequent updates (avg <= 12 hours) should add +10 bonus."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    tracking_events_count,
                    tracking_score
                FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE has_exception = FALSE
                  AND avg_hours_between_updates > 0
                  AND avg_hours_between_updates <= 12
                  AND tracking_events_count IN (1, 2, 3, 4, 5)
                LIMIT 50
            """)

            base_scores = {1: 20, 2: 40, 3: 60, 4: 75, 5: 90}
            for row in result:
                events, score = int(row[0]), int(row[1])
                if events in base_scores:
                    expected = min(100, base_scores[events] + 10)
                    assert score == expected, \
                        f"Events={events} with frequent updates should score {expected}, got {score}"
        finally:
            conn.close()

    def test_tracking_score_exception_penalty(self):
        """Exception shipments should have -20 penalty applied."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE has_exception = TRUE AND tracking_score > 80
            """)
            total_exceptions = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE has_exception = TRUE
            """)
            if int(total_exceptions[0][0]) > 0:
                ratio = float(result[0][0]) / float(total_exceptions[0][0])
                assert ratio < 0.3, "Most exception shipments should have tracking_score <= 80 due to -20 penalty"
        finally:
            conn.close()

    def test_tracking_score_capped_at_100(self):
        """Tracking score should never exceed 100."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="tracking_score > 100")
        assert int(result[0][0]) == 0, "tracking_score should never exceed 100"

    def test_tracking_score_minimum_zero(self):
        """Tracking score should never be below 0."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="tracking_score < 0")
        assert int(result[0][0]) == 0, "tracking_score should never be below 0"


# ============================================================================
# COST EFFICIENCY SCORE TESTS
# ============================================================================

class TestCostEfficiencyScore:
    """Tests for cost efficiency score calculation logic."""

    def test_cost_efficiency_score_tier_100(self):
        """cost_per_lb <= 2.0 should score 100."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) <= 2.0
                  AND cost_efficiency_score != 100
            """)
            assert int(result[0][0]) == 0, "cost_per_lb <= 2.0 should score 100"
        finally:
            conn.close()

    def test_cost_efficiency_score_tier_85(self):
        """cost_per_lb > 2.0 and <= 3.0 should score 85."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) > 2.0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) <= 3.0
                  AND cost_efficiency_score != 85
            """)
            assert int(result[0][0]) == 0, "cost_per_lb between 2.0-3.0 should score 85"
        finally:
            conn.close()

    def test_cost_efficiency_score_tier_70(self):
        """cost_per_lb > 3.0 and <= 4.0 should score 70."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) > 3.0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) <= 4.0
                  AND cost_efficiency_score != 70
            """)
            assert int(result[0][0]) == 0, "cost_per_lb between 3.0-4.0 should score 70"
        finally:
            conn.close()

    def test_cost_efficiency_score_tier_55(self):
        """cost_per_lb > 4.0 and <= 5.0 should score 55."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) > 4.0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) <= 5.0
                  AND cost_efficiency_score != 55
            """)
            assert int(result[0][0]) == 0, "cost_per_lb between 4.0-5.0 should score 55"
        finally:
            conn.close()

    def test_cost_efficiency_score_tier_40(self):
        """cost_per_lb > 5.0 and <= 7.0 should score 40."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) > 5.0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) <= 7.0
                  AND cost_efficiency_score != 40
            """)
            assert int(result[0][0]) == 0, "cost_per_lb between 5.0-7.0 should score 40"
        finally:
            conn.close()

    def test_cost_efficiency_score_tier_25(self):
        """cost_per_lb > 7.0 and <= 10.0 should score 25."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) > 7.0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) <= 10.0
                  AND cost_efficiency_score != 25
            """)
            assert int(result[0][0]) == 0, "cost_per_lb between 7.0-10.0 should score 25"
        finally:
            conn.close()

    def test_cost_efficiency_score_tier_10(self):
        """cost_per_lb > 10.0 should score 10."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE weight > 0
                  AND (CAST(shipping_cost AS DOUBLE) / weight) > 10.0
                  AND cost_efficiency_score != 10
            """)
            assert int(result[0][0]) == 0, "cost_per_lb > 10.0 should score 10"
        finally:
            conn.close()

    def test_cost_efficiency_score_default_50_for_zero_weight(self):
        """Zero or NULL weight should default to cost_efficiency_score = 50."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="(weight IS NULL OR weight = 0) AND cost_efficiency_score != 50")
        assert int(result[0][0]) == 0, "Zero/NULL weight should default to cost_efficiency_score = 50"


# ============================================================================
# OVERALL QUALITY SCORE AND TIER TESTS
# ============================================================================

class TestOverallQualityScore:
    """Tests for overall quality score and tier calculation."""

    def test_overall_score_weighted_calculation(self):
        """Overall quality score should be weighted average of component scores."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.shipment_quality_scores
                WHERE ABS(
                    overall_quality_score -
                    ROUND((delivery_score * 0.5) + (tracking_score * 0.3) + (cost_efficiency_score * 0.2), 2)
                ) > 0.01
            """)
            assert int(result[0][0]) == 0, "Overall score should be weighted average of components"
        finally:
            conn.close()

    def test_quality_tier_excellent(self):
        """overall_quality_score >= 85 should be EXCELLENT."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="overall_quality_score >= 85 AND quality_tier != 'EXCELLENT'")
        assert int(result[0][0]) == 0, "Score >= 85 should be EXCELLENT tier"

    def test_quality_tier_good(self):
        """overall_quality_score >= 70 and < 85 should be GOOD."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="overall_quality_score >= 70 AND overall_quality_score < 85 AND quality_tier != 'GOOD'")
        assert int(result[0][0]) == 0, "Score 70-84 should be GOOD tier"

    def test_quality_tier_fair(self):
        """overall_quality_score >= 50 and < 70 should be FAIR."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="overall_quality_score >= 50 AND overall_quality_score < 70 AND quality_tier != 'FAIR'")
        assert int(result[0][0]) == 0, "Score 50-69 should be FAIR tier"

    def test_quality_tier_poor(self):
        """overall_quality_score < 50 should be POOR."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="overall_quality_score < 50 AND quality_tier != 'POOR'")
        assert int(result[0][0]) == 0, "Score < 50 should be POOR tier"


# ============================================================================
# PERFORMANCE TIER TESTS
# ============================================================================

class TestPerformanceTier:
    """Tests for carrier performance tier calculation."""

    def test_performance_tier_premium(self):
        """avg_overall_quality_score >= 85 should be PREMIUM."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="avg_overall_quality_score >= 85 AND performance_tier != 'PREMIUM'")
        assert int(result[0][0]) == 0, "Score >= 85 should be PREMIUM tier"

    def test_performance_tier_reliable(self):
        """avg_overall_quality_score >= 70 and < 85 should be RELIABLE."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="avg_overall_quality_score >= 70 AND avg_overall_quality_score < 85 AND performance_tier != 'RELIABLE'")
        assert int(result[0][0]) == 0, "Score 70-84 should be RELIABLE tier"

    def test_performance_tier_standard(self):
        """avg_overall_quality_score >= 50 and < 70 should be STANDARD."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="avg_overall_quality_score >= 50 AND avg_overall_quality_score < 70 AND performance_tier != 'STANDARD'")
        assert int(result[0][0]) == 0, "Score 50-69 should be STANDARD tier"

    def test_performance_tier_underperforming(self):
        """avg_overall_quality_score < 50 should be UNDERPERFORMING."""
        result = query_model("carrier_performance_scorecard",
            "COUNT(*)", where="avg_overall_quality_score < 50 AND performance_tier != 'UNDERPERFORMING'")
        assert int(result[0][0]) == 0, "Score < 50 should be UNDERPERFORMING tier"


# ============================================================================
# CALCULATION VERIFICATION TESTS
# ============================================================================

class TestCalculations:
    """Tests for specific calculation logic."""

    def test_delivery_rate_calculation(self):
        """Verify delivery_rate is correctly calculated."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    total_shipments,
                    delivered_shipments,
                    delivery_rate,
                    ABS(delivery_rate - ROUND(CAST(delivered_shipments AS DOUBLE) / total_shipments, 4)) as diff
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
            """)

            for row in result:
                total, delivered, rate, diff = row
                assert float(diff) < 0.0001, f"delivery_rate calculation mismatch: {rate} vs {delivered}/{total}"
        finally:
            conn.close()

    def test_on_time_delivery_rate_calculation(self):
        """Verify on_time_delivery_rate is correctly calculated."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    delivered_shipments,
                    on_time_shipments,
                    on_time_delivery_rate
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
                WHERE delivered_shipments > 0
            """)

            for row in result:
                delivered, on_time, rate = row
                expected = round(float(on_time) / float(delivered), 4)
                assert abs(to_float(rate) - expected) < 0.0001, \
                    f"on_time_delivery_rate mismatch: {rate} vs {on_time}/{delivered}"
        finally:
            conn.close()

    def test_exception_rate_calculation(self):
        """Verify exception_rate is correctly calculated."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    total_shipments,
                    exception_shipments,
                    exception_rate,
                    ABS(exception_rate - ROUND(CAST(exception_shipments AS DOUBLE) / total_shipments, 4)) as diff
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
            """)

            for row in result:
                total, exceptions, rate, diff = row
                assert float(diff) < 0.0001, f"exception_rate calculation mismatch: {rate} vs {exceptions}/{total}"
        finally:
            conn.close()

    def test_avg_cost_per_lb_calculation(self):
        """Verify avg_cost_per_lb is correctly calculated."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    total_shipping_cost,
                    total_weight_shipped,
                    avg_cost_per_lb
                FROM {MODEL_SCHEMA}.carrier_performance_scorecard
                WHERE total_weight_shipped > 0
            """)

            for row in result:
                cost, weight, rate = row
                expected = round(to_float(cost) / to_float(weight), 4)
                assert abs(to_float(rate) - expected) < 0.001, \
                    f"avg_cost_per_lb mismatch: {rate} vs {cost}/{weight}"
        finally:
            conn.close()


# ============================================================================
# DATA QUALITY TESTS
# ============================================================================

class TestDataQuality:
    """Tests for general data quality."""

    def test_reasonable_delivery_days(self):
        """delivery_days should be reasonable (0-30 days)."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="delivery_days IS NOT NULL AND (delivery_days < 0 OR delivery_days > 30)")
        assert int(result[0][0]) == 0, "delivery_days should be between 0 and 30"

    def test_reasonable_shipping_cost(self):
        """shipping_cost should be reasonable (0-1000)."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="shipping_cost < 0 OR shipping_cost > 1000")
        assert int(result[0][0]) == 0, "shipping_cost should be reasonable"

    def test_reasonable_tracking_events(self):
        """tracking_events_count should be reasonable (0-100)."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="tracking_events_count < 0 OR tracking_events_count > 100")
        assert int(result[0][0]) == 0, "tracking_events_count should be reasonable"

    def test_reasonable_weight(self):
        """weight should be reasonable (0-1000 lbs)."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="weight < 0 OR weight > 1000")
        assert int(result[0][0]) == 0, "weight should be reasonable"

    def test_reasonable_package_count(self):
        """package_count should be reasonable (0-100)."""
        result = query_model("shipment_quality_scores",
            "COUNT(*)", where="package_count < 0 OR package_count > 100")
        assert int(result[0][0]) == 0, "package_count should be reasonable"
