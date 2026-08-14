"""
Tests for Warehouse Capacity Planning & Peak Load Analysis task.

Validates all 7 dbt models across staging, intermediate, and marts layers.
Supports both DuckDB and Snowflake backends via DB_TYPE environment variable.
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
    """Create a database connection based on DB_TYPE environment variable.
    Returns (conn, db_type) tuple."""
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


# ============ SCHEMA HELPER ============

def _get_schema_prefix():
    """Get schema prefix for queries based on DB_TYPE.
    For Snowflake with lowercase views in "main" schema, we can query
    directly. For DuckDB, schemas are main_staging, main_intermediate, main_marts."""
    return ""


def _schema_for(layer):
    """Return the schema name for a given layer (staging, intermediate, marts)."""
    return f"main_{layer}"


# ============ Helper functions ============

def table_exists(conn, db_type, schema, table):
    """Check if a table exists in the given schema"""
    query = """
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE lower(table_schema) = lower(%s)
        AND lower(table_name) = lower(%s)
    """ if db_type == 'snowflake' else """
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE lower(table_schema) = ?
        AND lower(table_name) = ?
    """
    result = execute_scalar(conn, db_type, query, [schema, table])
    return int(result) >= 1


def get_columns(conn, db_type, schema, table):
    """Get column names and types for a table"""
    query = """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = lower(%s)
        AND lower(table_name) = lower(%s)
    """ if db_type == 'snowflake' else """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = ?
        AND lower(table_name) = ?
    """
    columns = execute_query(conn, db_type, query, [schema, table])
    return {col[0].lower(): col[1] for col in columns}


def type_matches(actual_type, accepted_types):
    """Check if actual type matches any accepted type (handles DECIMAL(n,m) variants)"""
    actual_upper = actual_type.upper() if actual_type else ''
    for t in accepted_types:
        t_upper = t.upper()
        if actual_upper == t_upper:
            return True
        # Handle DECIMAL(n,m) matching DECIMAL
        if t_upper == 'DECIMAL' and actual_upper.startswith('DECIMAL'):
            return True
        if t_upper == 'NUMERIC' and actual_upper.startswith('NUMERIC'):
            return True
        # Snowflake NUMBER type matching
        if t_upper in ('INTEGER', 'BIGINT') and actual_upper.startswith('NUMBER'):
            return True
        if t_upper in ('DOUBLE', 'FLOAT') and actual_upper.startswith('NUMBER'):
            return True
        if t_upper == 'DOUBLE' and actual_upper == 'FLOAT':
            return True
        if t_upper == 'FLOAT' and actual_upper == 'DOUBLE':
            return True
        # Snowflake TEXT = VARCHAR
        if t_upper == 'VARCHAR' and actual_upper in ('TEXT', 'VARCHAR'):
            return True
        # Snowflake TIMESTAMP_NTZ
        if t_upper in ('TIMESTAMP', 'TIMESTAMP WITH TIME ZONE') and 'TIMESTAMP' in actual_upper:
            return True
    return False


def row_count(conn, db_type, schema, table):
    """Get row count for a table"""
    result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {schema}.{table}")
    return int(result)


# =============================================================================
# Staging Model Tests
# =============================================================================

class TestStagingOrders:
    """Tests for stg_capacity__orders model"""

    def test_model_exists(self):
        """Test that stg_capacity__orders model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_staging', 'stg_capacity__orders'), \
                "stg_capacity__orders model does not exist in staging schema"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test that staging orders has required columns"""
        required = {
            'order_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'ordered_at': ['TIMESTAMP', 'TIMESTAMP WITH TIME ZONE'],
            'order_date': ['DATE'],
            'order_hour': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT'],
            'day_of_week': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT'],
            'grand_total': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_staging', 'stg_capacity__orders')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_has_data(self):
        """Test that staging orders has data"""
        conn, db_type = get_db_connection()
        try:
            count = row_count(conn, db_type, 'main_staging', 'stg_capacity__orders')
            assert count > 0, "stg_capacity__orders is empty"
        finally:
            conn.close()

    def test_order_hour_range(self):
        """Test that order_hour is between 0 and 23"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_staging.stg_capacity__orders
                WHERE order_hour < 0 OR order_hour > 23
            """)
            assert int(result) == 0, "order_hour values outside 0-23 range"
        finally:
            conn.close()

    def test_day_of_week_range(self):
        """Test that day_of_week is between 0 and 6"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_staging.stg_capacity__orders
                WHERE day_of_week < 0 OR day_of_week > 6
            """)
            assert int(result) == 0, "day_of_week values outside 0-6 range"
        finally:
            conn.close()

    def test_no_null_warehouse(self):
        """Test that all orders have warehouse_id"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_staging.stg_capacity__orders
                WHERE warehouse_id IS NULL
            """)
            assert int(result) == 0, "Found orders with NULL warehouse_id"
        finally:
            conn.close()


class TestStagingShipments:
    """Tests for stg_capacity__shipments model"""

    def test_model_exists(self):
        """Test that stg_capacity__shipments model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_staging', 'stg_capacity__shipments'), \
                "stg_capacity__shipments model does not exist in staging schema"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test that staging shipments has required columns"""
        required = {
            'shipment_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'order_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'shipped_at': ['TIMESTAMP', 'TIMESTAMP WITH TIME ZONE'],
            'shipment_date': ['DATE'],
            'shipment_hour': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT'],
            'status': ['VARCHAR']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_staging', 'stg_capacity__shipments')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_has_data(self):
        """Test that staging shipments has data"""
        conn, db_type = get_db_connection()
        try:
            count = row_count(conn, db_type, 'main_staging', 'stg_capacity__shipments')
            assert count > 0, "stg_capacity__shipments is empty"
        finally:
            conn.close()


# =============================================================================
# Intermediate Model Tests
# =============================================================================

class TestHourlyVolume:
    """Tests for int_capacity__hourly_volume model"""

    def test_model_exists(self):
        """Test that int_capacity__hourly_volume model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_intermediate', 'int_capacity__hourly_volume'), \
                "int_capacity__hourly_volume model does not exist"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test required columns"""
        required = {
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'volume_date': ['DATE'],
            'volume_hour': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT'],
            'order_count': ['INTEGER', 'BIGINT'],
            'shipment_count': ['INTEGER', 'BIGINT'],
            'order_value': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_intermediate', 'int_capacity__hourly_volume')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_grain_uniqueness(self):
        """Test that grain is unique (warehouse_id, volume_date, volume_hour)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM (
                    SELECT warehouse_id, volume_date, volume_hour, COUNT(*) as cnt
                    FROM main_intermediate.int_capacity__hourly_volume
                    GROUP BY warehouse_id, volume_date, volume_hour
                    HAVING COUNT(*) > 1
                )
            """)
            assert int(result) == 0, "Duplicate grain combinations found"
        finally:
            conn.close()

    def test_order_count_non_negative(self):
        """Test that order_count is non-negative"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__hourly_volume
                WHERE order_count < 0
            """)
            assert int(result) == 0, "Negative order_count values found"
        finally:
            conn.close()

    def test_complete_24_hour_grid(self):
        """Test that each warehouse-day has all 24 hours (0-23)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM (
                    SELECT warehouse_id, volume_date, COUNT(DISTINCT volume_hour) as hour_count
                    FROM main_intermediate.int_capacity__hourly_volume
                    GROUP BY warehouse_id, volume_date
                    HAVING hour_count <> 24
                )
            """)
            assert int(result) == 0, "Missing or extra hours found in int_capacity__hourly_volume"
        finally:
            conn.close()


class TestDailyUtilization:
    """Tests for int_capacity__daily_utilization model"""

    def test_model_exists(self):
        """Test that int_capacity__daily_utilization model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_intermediate', 'int_capacity__daily_utilization'), \
                "int_capacity__daily_utilization model does not exist"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test required columns"""
        required = {
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'utilization_date': ['DATE'],
            'daily_orders': ['INTEGER', 'BIGINT'],
            'daily_shipments': ['INTEGER', 'BIGINT'],
            'daily_order_value': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'location_count': ['INTEGER', 'BIGINT'],
            'theoretical_daily_capacity': ['INTEGER', 'BIGINT', 'DOUBLE', 'FLOAT'],
            'utilization_rate': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_intermediate', 'int_capacity__daily_utilization')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_grain_uniqueness(self):
        """Test grain uniqueness"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM (
                    SELECT warehouse_id, utilization_date, COUNT(*) as cnt
                    FROM main_intermediate.int_capacity__daily_utilization
                    GROUP BY warehouse_id, utilization_date
                    HAVING COUNT(*) > 1
                )
            """)
            assert int(result) == 0, "Duplicate grain combinations found"
        finally:
            conn.close()

    def test_utilization_rate_reasonable(self):
        """Test that utilization rates are within reasonable bounds (0-2)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__daily_utilization
                WHERE utilization_rate < 0 OR utilization_rate > 2
            """)
            assert int(result) == 0, "Utilization rates outside 0-2 range"
        finally:
            conn.close()

    def test_theoretical_capacity_formula(self):
        """Test that theoretical_daily_capacity = location_count * 0.05"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__daily_utilization
                WHERE ABS(theoretical_daily_capacity - (location_count * 0.05)) > 0.01
            """)
            assert int(result) == 0, "Theoretical capacity formula incorrect"
        finally:
            conn.close()

    def test_utilization_rate_formula(self):
        """Test that utilization_rate = daily_orders / theoretical_daily_capacity"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__daily_utilization
                WHERE theoretical_daily_capacity > 0
                AND ABS(utilization_rate - (CAST(daily_orders AS DOUBLE) / theoretical_daily_capacity)) > 0.001
            """)
            assert int(result) == 0, "Utilization rate formula incorrect"
        finally:
            conn.close()


class TestPeakPeriods:
    """Tests for int_capacity__peak_periods model"""

    def test_model_exists(self):
        """Test that int_capacity__peak_periods model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_intermediate', 'int_capacity__peak_periods'), \
                "int_capacity__peak_periods model does not exist"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test required columns"""
        required = {
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'volume_date': ['DATE'],
            'volume_hour': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT'],
            'order_count': ['INTEGER', 'BIGINT'],
            'shipment_count': ['INTEGER', 'BIGINT'],
            'volume_percentile': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT'],
            'is_peak_hour': ['INTEGER', 'BIGINT', 'TINYINT', 'SMALLINT', 'BOOLEAN']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_intermediate', 'int_capacity__peak_periods')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_percentile_range(self):
        """Test that volume_percentile is between 1 and 100"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__peak_periods
                WHERE volume_percentile < 1 OR volume_percentile > 100
            """)
            assert int(result) == 0, "volume_percentile outside 1-100 range"
        finally:
            conn.close()

    def test_peak_hour_detection(self):
        """Test that is_peak_hour = 1 when volume_percentile >= 90"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__peak_periods
                WHERE (volume_percentile >= 90 AND is_peak_hour != 1)
                   OR (volume_percentile < 90 AND is_peak_hour != 0)
            """)
            assert int(result) == 0, "Peak hour detection logic incorrect"
        finally:
            conn.close()

    def test_peak_hours_exist(self):
        """Test that some peak hours are identified"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_intermediate.int_capacity__peak_periods
                WHERE is_peak_hour = 1
            """)
            assert int(result) > 0, "No peak hours identified"
        finally:
            conn.close()


# =============================================================================
# Mart Model Tests
# =============================================================================

class TestWarehouseCapacity:
    """Tests for fct_warehouse_capacity model"""

    def test_model_exists(self):
        """Test that fct_warehouse_capacity model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_marts', 'fct_warehouse_capacity'), \
                "fct_warehouse_capacity model does not exist"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test required columns"""
        required = {
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'capacity_date': ['DATE'],
            'total_orders': ['INTEGER', 'BIGINT'],
            'total_shipments': ['INTEGER', 'BIGINT'],
            'total_order_value': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'utilization_rate': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'peak_hour_count': ['INTEGER', 'BIGINT'],
            'avg_hourly_orders': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'max_hourly_orders': ['INTEGER', 'BIGINT'],
            'peak_load_factor': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'capacity_headroom_pct': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'rolling_7d_avg_orders': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_marts', 'fct_warehouse_capacity')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_grain_uniqueness(self):
        """Test grain uniqueness"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM (
                    SELECT warehouse_id, capacity_date, COUNT(*) as cnt
                    FROM main_marts.fct_warehouse_capacity
                    GROUP BY warehouse_id, capacity_date
                    HAVING COUNT(*) > 1
                )
            """)
            assert int(result) == 0, "Duplicate grain combinations found"
        finally:
            conn.close()

    def test_has_data(self):
        """Test that fact table has data"""
        conn, db_type = get_db_connection()
        try:
            count = row_count(conn, db_type, 'main_marts', 'fct_warehouse_capacity')
            assert count > 0, "fct_warehouse_capacity is empty"
        finally:
            conn.close()

    def test_peak_load_factor_valid(self):
        """Test that peak_load_factor >= 1.0 (max is always >= avg)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.fct_warehouse_capacity
                WHERE peak_load_factor IS NOT NULL AND peak_load_factor < 1.0
            """)
            assert int(result) == 0, "peak_load_factor values < 1.0 found (invalid)"
        finally:
            conn.close()

    def test_no_null_peak_load_factor(self):
        """Test that peak_load_factor is not null"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.fct_warehouse_capacity
                WHERE peak_load_factor IS NULL
            """)
            assert int(result) == 0, "NULL peak_load_factor values found"
        finally:
            conn.close()

    def test_peak_load_factor_zero_avg(self):
        """Test that peak_load_factor defaults to 1.0 when avg_hourly_orders = 0"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.fct_warehouse_capacity
                WHERE avg_hourly_orders = 0
                  AND (peak_load_factor IS NULL OR ABS(peak_load_factor - 1.0) > 0.0001)
            """)
            assert int(result) == 0, "avg_hourly_orders = 0 should yield peak_load_factor = 1.0"
        finally:
            conn.close()

    def test_no_null_utilization(self):
        """Test that utilization_rate is not null"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.fct_warehouse_capacity
                WHERE utilization_rate IS NULL
            """)
            assert int(result) == 0, "NULL utilization_rate values found"
        finally:
            conn.close()

    def test_capacity_headroom_formula(self):
        """Test that capacity_headroom_pct = (1 - utilization_rate) * 100"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.fct_warehouse_capacity
                WHERE ABS(capacity_headroom_pct - ((1 - utilization_rate) * 100)) > 0.1
            """)
            assert int(result) == 0, "capacity_headroom_pct formula incorrect"
        finally:
            conn.close()

    def test_rolling_7d_avg_orders_formula(self):
        """Test rolling 7-day average of total_orders per warehouse"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM (
                    SELECT
                        warehouse_id,
                        capacity_date,
                        rolling_7d_avg_orders,
                        AVG(total_orders) OVER (
                            PARTITION BY warehouse_id
                            ORDER BY capacity_date
                            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
                        ) AS expected_rolling
                    FROM main_marts.fct_warehouse_capacity
                )
                WHERE ABS(rolling_7d_avg_orders - expected_rolling) > 0.0001
            """)
            assert int(result) == 0, "rolling_7d_avg_orders formula incorrect"
        finally:
            conn.close()

    def test_multiple_warehouses(self):
        """Test that we have metrics for multiple warehouses"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(DISTINCT warehouse_id) FROM main_marts.fct_warehouse_capacity
            """)
            assert int(result) >= 2, f"Expected metrics for at least 2 warehouses, found {int(result)}"
        finally:
            conn.close()


class TestCapacityBottlenecks:
    """Tests for rpt_capacity_bottlenecks model"""

    def test_model_exists(self):
        """Test that rpt_capacity_bottlenecks model exists"""
        conn, db_type = get_db_connection()
        try:
            assert table_exists(conn, db_type, 'main_marts', 'rpt_capacity_bottlenecks'), \
                "rpt_capacity_bottlenecks model does not exist"
        finally:
            conn.close()

    def test_required_columns(self):
        """Test required columns"""
        required = {
            'warehouse_id': ['INTEGER', 'VARCHAR', 'BIGINT'],
            'capacity_date': ['DATE'],
            'utilization_rate': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'total_orders': ['INTEGER', 'BIGINT'],
            'peak_load_factor': ['DECIMAL', 'DOUBLE', 'FLOAT', 'NUMERIC'],
            'bottleneck_severity': ['VARCHAR']
        }
        conn, db_type = get_db_connection()
        try:
            columns = get_columns(conn, db_type, 'main_marts', 'rpt_capacity_bottlenecks')
            for col, types in required.items():
                assert col in columns, f"Missing column: {col}"
                assert type_matches(columns[col], types), f"Wrong type for {col}: got {columns[col]}"
        finally:
            conn.close()

    def test_bottleneck_threshold(self):
        """Test that all rows have utilization_rate >= 0.75"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.rpt_capacity_bottlenecks
                WHERE utilization_rate < 0.75
            """)
            assert int(result) == 0, "Found bottleneck entries with utilization_rate < 0.75"
        finally:
            conn.close()

    def test_severity_values(self):
        """Test that bottleneck_severity has valid values"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.rpt_capacity_bottlenecks
                WHERE bottleneck_severity NOT IN ('CRITICAL', 'HIGH', 'MODERATE')
            """)
            assert int(result) == 0, "Invalid bottleneck_severity values found"
        finally:
            conn.close()

    def test_severity_logic(self):
        """Test that severity classification is correct"""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM main_marts.rpt_capacity_bottlenecks
                WHERE (utilization_rate >= 0.95 AND bottleneck_severity != 'CRITICAL')
                   OR (utilization_rate >= 0.85 AND utilization_rate < 0.95 AND bottleneck_severity != 'HIGH')
                   OR (utilization_rate >= 0.75 AND utilization_rate < 0.85 AND bottleneck_severity != 'MODERATE')
            """)
            assert int(result) == 0, "Bottleneck severity logic incorrect"
        finally:
            conn.close()

    def test_has_bottleneck_data(self):
        """Test that at least one bottleneck is identified"""
        conn, db_type = get_db_connection()
        try:
            count = row_count(conn, db_type, 'main_marts', 'rpt_capacity_bottlenecks')
            assert count > 0, "No bottlenecks identified - expected at least one warehouse-day with high utilization"
        finally:
            conn.close()
