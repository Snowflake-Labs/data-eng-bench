"""Verifier for the DBT Order Fulfillment Analytics challenge."""

from __future__ import annotations

import subprocess
from pathlib import Path
import pytest
import os


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


def _param_placeholder(db_type):
    """Return the parameter placeholder for the given DB type."""
    return '%s' if db_type == 'snowflake' else '?'


def ensure_snowflake_schemas():
    """Create required schemas in Snowflake using admin role if available."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type != 'snowflake':
        return
    admin_role = os.environ.get('SNOWFLAKE_ADMIN_ROLE', '')
    if not admin_role:
        return

    import base64
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization
    import snowflake.connector

    pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
    pk_pem = base64.b64decode(pk_b64)
    pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    pp_bytes = pp.encode() if pp else None
    p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
    pkb = p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )

    conn = snowflake.connector.connect(
        account=os.environ['SNOWFLAKE_ACCOUNT'],
        host=os.environ.get('SNOWFLAKE_HOST') or None,
        user=os.environ['SNOWFLAKE_USER'],
        private_key=pkb,
        warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
        role=admin_role,
        database=os.environ['SNOWFLAKE_DATABASE'],
    )
    cur = conn.cursor()
    agent_role = os.environ.get('SNOWFLAKE_AGENT_ROLE', os.environ.get('SNOWFLAKE_ROLE', ''))
    db = os.environ['SNOWFLAKE_DATABASE']

    try:
        cur.execute(f"GRANT CREATE SCHEMA ON DATABASE {db} TO ROLE {agent_role}")
    except Exception:
        pass

    for schema_name in ['staging', 'intermediate', 'marts']:
        try:
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}")
            cur.execute(f"GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
            cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
            cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
            cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
            cur.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
        except Exception:
            pass
    conn.close()


# ============ END DUAL-BACKEND INFRASTRUCTURE ============


REQUIRED_STAGING_TABLES = [
    "stg_orders",
    "stg_order_lines",
    "stg_shipments",
    "stg_shipment_lines",
    "stg_order_status_history",
    "stg_returns",
]

REQUIRED_INTERMEDIATE_TABLES = [
    "int_order_lifecycle",
    "int_shipment_performance",
    "int_order_fulfillment_status",
    "int_order_revenue_summary",
]

REQUIRED_MART_TABLES = [
    "mart_fulfillment_metrics",
    "mart_return_analysis",
    "mart_carrier_performance",
    "mart_order_status_flow",
    "mart_daily_revenue",
]

INT_ORDER_LIFECYCLE_COLS = {
    "order_id", "order_number", "customer_id", "order_type", "order_source",
    "status", "grand_total", "ordered_at",
    "first_status_change_at", "time_to_first_ship_hours",
    "time_to_delivery_hours", "status_change_count"
}

INT_SHIPMENT_PERFORMANCE_COLS = {
    "shipment_id", "shipment_number", "order_id", "warehouse_id", "carrier_id",
    "status", "shipped_at", "delivered_at",
    "items_in_shipment", "total_quantity_shipped",
    "shipping_cost", "transit_time_hours"
}

INT_ORDER_FULFILLMENT_STATUS_COLS = {
    "order_id", "order_number", "ordered_at",
    "total_lines", "total_quantity_ordered",
    "total_quantity_shipped", "total_quantity_returned",
    "fulfillment_pct", "is_fully_fulfilled", "is_partially_fulfilled"
}

INT_ORDER_REVENUE_SUMMARY_COLS = {
    "order_id", "order_date", "warehouse_id",
    "line_item_count", "gross_revenue", "shipping_revenue", "total_revenue"
}

MART_FULFILLMENT_METRICS_COLS = {
    "warehouse_id", "order_date",
    "total_orders", "total_order_value", "total_shipments",
    "orders_fully_fulfilled", "orders_partially_fulfilled",
    "fulfillment_rate", "avg_time_to_ship_hours", "avg_time_to_delivery_hours"
}

MART_RETURN_ANALYSIS_COLS = {
    "return_type", "return_month",
    "total_returns", "total_refund_amount", "avg_refund_amount",
    "returns_processed", "returns_rejected",
    "processing_rate", "avg_processing_time_days"
}

MART_CARRIER_PERFORMANCE_COLS = {
    "carrier_id",
    "total_shipments", "shipments_delivered", "shipments_failed", "in_transit_shipments",
    "delivery_rate", "failed_shipment_rate",
    "total_shipping_cost", "avg_shipping_cost",
    "avg_transit_time_hours_delivered_only", "on_time_delivery_count"
}

MART_ORDER_STATUS_FLOW_COLS = {
    "old_status", "new_status",
    "transition_count", "unique_orders",
    "avg_time_in_old_status_hours", "pct_of_all_transitions"
}

MART_DAILY_REVENUE_COLS = {
    "order_date", "order_count", "line_item_count",
    "gross_revenue", "shipping_revenue", "total_revenue", "avg_order_value"
}


def _table_exists(conn, db_type, schema, table):
    ph = _param_placeholder(db_type)
    q = f"""
    SELECT COUNT(*)
    FROM information_schema.tables
    WHERE lower(table_schema) = lower({ph})
      AND lower(table_name) = lower({ph})
    """
    return int(execute_scalar(conn, db_type, q, [schema, table])) > 0


def _rowcount(conn, db_type, schema, table):
    return int(execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {schema}.{table}"))


def _cols(conn, db_type, schema, table):
    ph = _param_placeholder(db_type)
    q = f"""
    SELECT lower(column_name)
    FROM information_schema.columns
    WHERE lower(table_schema) = lower({ph})
      AND lower(table_name) = lower({ph})
    """
    rows = execute_query(conn, db_type, q, [schema, table])
    return {r[0] for r in rows}


def _approx_equal(a, b, tol=0.01):
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    return abs(float(a) - float(b)) <= tol


# Models to build for this task (avoids building 2000+ models in the existing project)
MODELS_TO_BUILD = (
    REQUIRED_STAGING_TABLES +
    REQUIRED_INTERMEDIATE_TABLES +
    REQUIRED_MART_TABLES
)


@pytest.fixture(scope="session", autouse=True)
def run_dbt():
    """Run dbt commands before tests.

    Only builds the specific models required for this task, not the entire
    existing project which may have pre-existing errors.
    """
    # Ensure required Snowflake schemas exist before dbt run
    ensure_snowflake_schemas()

    dbt_project_dir = get_dbt_project_dir()
    DBT_PROJECT_PATH = Path(dbt_project_dir)
    assert DBT_PROJECT_PATH.exists(), f"dbt project not found at {DBT_PROJECT_PATH}"
    assert (DBT_PROJECT_PATH / "dbt_project.yml").exists(), "Missing dbt_project.yml"
    assert (DBT_PROJECT_PATH / "profiles.yml").exists(), "Missing profiles.yml"

    # Install dbt package dependencies
    deps_result = subprocess.run(
        ["dbt", "deps", "--profiles-dir", "."],
        cwd=str(DBT_PROJECT_PATH),
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert deps_result.returncode == 0, f"dbt deps failed:\n{deps_result.stdout}\n{deps_result.stderr}"

    # Build only the models required for this task
    result = subprocess.run(
        ["dbt", "run", "--profiles-dir", ".", "--select"] + MODELS_TO_BUILD,
        cwd=str(DBT_PROJECT_PATH),
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert result.returncode == 0, f"dbt run failed:\n{result.stdout}\n{result.stderr}"

    # Run tests only for the models we built
    result = subprocess.run(
        ["dbt", "test", "--profiles-dir", ".", "--select"] + MODELS_TO_BUILD,
        cwd=str(DBT_PROJECT_PATH),
        capture_output=True,
        text=True,
        timeout=300,
    )
    # Note: dbt test may return non-zero if there are no tests defined, which is OK
    # We only fail if there are actual test failures
    if result.returncode != 0 and "FAIL" in result.stdout:
        assert False, f"dbt test failed:\n{result.stdout}\n{result.stderr}"


@pytest.fixture(scope="session")
def db_connection(run_dbt):
    """Create database connection AFTER dbt has built the models."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ============================================================
# STAGING MODEL TESTS
# ============================================================

class TestStagingModels:
    @pytest.mark.parametrize("table_name", REQUIRED_STAGING_TABLES)
    def test_staging_table_exists(self, db_connection, table_name):
        """Verify each required staging table exists and has rows."""
        conn, db_type = db_connection
        assert _table_exists(conn, db_type, "staging", table_name), \
            f"Missing staging table: staging.{table_name}"
        assert _rowcount(conn, db_type, "staging", table_name) > 0, \
            f"Staging table has no rows: staging.{table_name}"


# ============================================================
# INTERMEDIATE MODEL TESTS
# ============================================================

class TestIntermediateModels:
    @pytest.mark.parametrize("table_name", REQUIRED_INTERMEDIATE_TABLES)
    def test_intermediate_table_exists(self, db_connection, table_name):
        """Verify each required intermediate table exists and has rows."""
        conn, db_type = db_connection
        assert _table_exists(conn, db_type, "intermediate", table_name), \
            f"Missing intermediate table: intermediate.{table_name}"
        assert _rowcount(conn, db_type, "intermediate", table_name) > 0, \
            f"Intermediate table has no rows: intermediate.{table_name}"

    def test_int_order_lifecycle_columns(self, db_connection):
        """Verify int_order_lifecycle contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "intermediate", "int_order_lifecycle")
        missing = INT_ORDER_LIFECYCLE_COLS - actual
        assert not missing, f"int_order_lifecycle missing columns: {missing}"

    def test_int_shipment_performance_columns(self, db_connection):
        """Verify int_shipment_performance contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "intermediate", "int_shipment_performance")
        missing = INT_SHIPMENT_PERFORMANCE_COLS - actual
        assert not missing, f"int_shipment_performance missing columns: {missing}"

    def test_int_order_fulfillment_status_columns(self, db_connection):
        """Verify int_order_fulfillment_status contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "intermediate", "int_order_fulfillment_status")
        missing = INT_ORDER_FULFILLMENT_STATUS_COLS - actual
        assert not missing, f"int_order_fulfillment_status missing columns: {missing}"

    def test_int_order_revenue_summary_columns(self, db_connection):
        """Verify int_order_revenue_summary contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "intermediate", "int_order_revenue_summary")
        missing = INT_ORDER_REVENUE_SUMMARY_COLS - actual
        assert not missing, f"int_order_revenue_summary missing columns: {missing}"


# ============================================================
# MART MODEL TESTS
# ============================================================

class TestMartModels:
    @pytest.mark.parametrize("table_name", REQUIRED_MART_TABLES)
    def test_mart_table_exists(self, db_connection, table_name):
        """Verify each required mart table exists and has rows."""
        conn, db_type = db_connection
        assert _table_exists(conn, db_type, "marts", table_name), \
            f"Missing mart table: marts.{table_name}"
        assert _rowcount(conn, db_type, "marts", table_name) > 0, \
            f"Mart table has no rows: marts.{table_name}"

    def test_mart_fulfillment_metrics_columns(self, db_connection):
        """Verify mart_fulfillment_metrics contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "marts", "mart_fulfillment_metrics")
        missing = MART_FULFILLMENT_METRICS_COLS - actual
        assert not missing, f"mart_fulfillment_metrics missing columns: {missing}"

    def test_mart_return_analysis_columns(self, db_connection):
        """Verify mart_return_analysis contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "marts", "mart_return_analysis")
        missing = MART_RETURN_ANALYSIS_COLS - actual
        assert not missing, f"mart_return_analysis missing columns: {missing}"

    def test_mart_carrier_performance_columns(self, db_connection):
        """Verify mart_carrier_performance contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "marts", "mart_carrier_performance")
        missing = MART_CARRIER_PERFORMANCE_COLS - actual
        assert not missing, f"mart_carrier_performance missing columns: {missing}"

    def test_mart_order_status_flow_columns(self, db_connection):
        """Verify mart_order_status_flow contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "marts", "mart_order_status_flow")
        missing = MART_ORDER_STATUS_FLOW_COLS - actual
        assert not missing, f"mart_order_status_flow missing columns: {missing}"

    def test_mart_daily_revenue_columns(self, db_connection):
        """Verify mart_daily_revenue contains all required columns."""
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "marts", "mart_daily_revenue")
        missing = MART_DAILY_REVENUE_COLS - actual
        assert not missing, f"mart_daily_revenue missing columns: {missing}"


# ============================================================
# METRICS CORRECTNESS TESTS
# ============================================================

class TestMetricsCorrectness:
    def test_total_orders_by_warehouse_date(self, db_connection):
        """Verify total_orders count matches source data."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT warehouse_id, order_date, total_orders
            FROM marts.mart_fulfillment_metrics
            LIMIT 5
        """)

        for warehouse_id, order_date, total_orders in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(DISTINCT ORDER_ID)
                FROM ORDERS.ORDERS
                WHERE WAREHOUSE_ID = {ph}
                  AND CAST(ORDERED_AT AS DATE) = CAST({ph} AS DATE)
            """, [warehouse_id, str(order_date)])
            assert int(total_orders) == int(expected), \
                f"total_orders incorrect for warehouse {warehouse_id}, date {order_date}"

    def test_total_shipments_by_carrier(self, db_connection):
        """Verify total_shipments count matches source data."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        mart_data = execute_query(conn, db_type, """
            SELECT carrier_id, total_shipments
            FROM marts.mart_carrier_performance
            ORDER BY carrier_id
        """)

        for carrier_id, total_shipments in mart_data:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.SHIPMENTS
                WHERE CARRIER_ID = {ph}
            """, [carrier_id])
            assert int(total_shipments) == int(expected), \
                f"total_shipments incorrect for carrier {carrier_id}"

    def test_return_counts_by_type_month(self, db_connection):
        """Verify return counts match source data."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT return_type, return_month, total_returns
            FROM marts.mart_return_analysis
            LIMIT 5
        """)

        for return_type, return_month, total_returns in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.RETURNS
                WHERE RETURN_TYPE = {ph}
                  AND DATE_TRUNC('month', REQUESTED_AT) = CAST({ph} AS DATE)
            """, [return_type, str(return_month)])
            assert int(total_returns) == int(expected), \
                f"total_returns incorrect for type {return_type}, month {return_month}"

    def test_status_transition_counts(self, db_connection):
        """Verify transition counts match source data."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT old_status, new_status, transition_count
            FROM marts.mart_order_status_flow
            WHERE old_status IS NOT NULL AND new_status IS NOT NULL
            LIMIT 5
        """)

        for old_status, new_status, transition_count in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.ORDER_STATUS_HISTORY
                WHERE OLD_STATUS = {ph}
                  AND NEW_STATUS = {ph}
            """, [old_status, new_status])
            assert int(transition_count) == int(expected), \
                f"transition_count incorrect for {old_status} -> {new_status}"

    def test_pct_of_all_transitions_sums_to_100(self, db_connection):
        """Verify percentage columns sum correctly."""
        conn, db_type = db_connection
        pct_sum = execute_scalar(conn, db_type, """
            SELECT SUM(pct_of_all_transitions)
            FROM marts.mart_order_status_flow
        """)
        assert _approx_equal(float(pct_sum), 100.0, tol=0.5), \
            f"pct_of_all_transitions should sum to 100, got {pct_sum}"

    def test_fulfillment_pct_calculation(self, db_connection):
        """Verify fulfillment percentage calculation."""
        conn, db_type = db_connection
        sample = execute_query(conn, db_type, """
            SELECT order_id, total_quantity_ordered, total_quantity_shipped, fulfillment_pct
            FROM intermediate.int_order_fulfillment_status
            WHERE total_quantity_ordered > 0
            LIMIT 10
        """)

        for order_id, qty_ordered, qty_shipped, fulfillment_pct in sample:
            expected_pct = (float(qty_shipped) / float(qty_ordered)) * 100
            assert _approx_equal(float(fulfillment_pct), expected_pct, tol=0.1), \
                f"fulfillment_pct incorrect for order {order_id}: expected {expected_pct}, got {fulfillment_pct}"

    def test_is_fully_fulfilled_flag(self, db_connection):
        """Verify is_fully_fulfilled flag logic."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, fulfillment_pct, is_fully_fulfilled
            FROM intermediate.int_order_fulfillment_status
            WHERE fulfillment_pct >= 100 AND is_fully_fulfilled != 1
        """)
        assert len(result) == 0, f"is_fully_fulfilled should be 1 when fulfillment_pct >= 100: {result}"

        result = execute_query(conn, db_type, """
            SELECT order_id, fulfillment_pct, is_fully_fulfilled
            FROM intermediate.int_order_fulfillment_status
            WHERE fulfillment_pct < 100 AND is_fully_fulfilled = 1
        """)
        assert len(result) == 0, f"is_fully_fulfilled should be 0 when fulfillment_pct < 100: {result}"

    def test_is_partially_fulfilled_flag(self, db_connection):
        """Verify is_partially_fulfilled flag logic."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, fulfillment_pct, is_partially_fulfilled
            FROM intermediate.int_order_fulfillment_status
            WHERE fulfillment_pct > 0 AND fulfillment_pct < 100 AND is_partially_fulfilled != 1
        """)
        assert len(result) == 0, f"is_partially_fulfilled should be 1 when 0 < fulfillment_pct < 100: {result}"

    def test_items_in_shipment_count(self, db_connection):
        """Verify items_in_shipment matches shipment_lines count."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT shipment_id, items_in_shipment
            FROM intermediate.int_shipment_performance
            LIMIT 5
        """)

        for shipment_id, items_count in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.SHIPMENT_LINES
                WHERE SHIPMENT_ID = {ph}
            """, [shipment_id])
            assert int(items_count) == int(expected), \
                f"items_in_shipment incorrect for shipment {shipment_id}"

    def test_status_change_count(self, db_connection):
        """Verify status_change_count matches history records."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT order_id, status_change_count
            FROM intermediate.int_order_lifecycle
            WHERE status_change_count > 0
            LIMIT 5
        """)

        for order_id, change_count in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.ORDER_STATUS_HISTORY
                WHERE ORDER_ID = {ph}
            """, [order_id])
            assert int(change_count) == int(expected), \
                f"status_change_count incorrect for order {order_id}"

    def test_on_time_delivery_threshold(self, db_connection):
        """Verify on_time_delivery_count uses 120 hour threshold."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT carrier_id, on_time_delivery_count
            FROM marts.mart_carrier_performance
            LIMIT 3
        """)

        for carrier_id, on_time_count in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.SHIPMENTS
                WHERE CARRIER_ID = {ph}
                  AND STATUS = 'DELIVERED'
                  AND DATEDIFF('second', SHIPPED_AT, DELIVERED_AT) / 3600.0 <= 120
            """, [carrier_id])
            assert int(on_time_count) == int(expected), \
                f"on_time_delivery_count incorrect for carrier {carrier_id}"

    def test_carrier_in_transit_shipments(self, db_connection):
        """Verify in_transit_shipments count."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT carrier_id, in_transit_shipments
            FROM marts.mart_carrier_performance
            LIMIT 3
        """)

        for carrier_id, in_transit_count in sample:
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.SHIPMENTS
                WHERE CARRIER_ID = {ph}
                  AND STATUS = 'IN_TRANSIT'
            """, [carrier_id])
            assert int(in_transit_count) == int(expected), \
                f"in_transit_shipments incorrect for carrier {carrier_id}"

    def test_carrier_failed_shipment_rate(self, db_connection):
        """Verify failed_shipment_rate calculation."""
        conn, db_type = db_connection
        sample = execute_query(conn, db_type, """
            SELECT carrier_id, total_shipments, shipments_failed, failed_shipment_rate
            FROM marts.mart_carrier_performance
            WHERE total_shipments > 0
            LIMIT 5
        """)

        for carrier_id, total, failed, rate in sample:
            expected_rate = (float(failed) / float(total)) * 100
            assert _approx_equal(float(rate), expected_rate, tol=0.1), \
                f"failed_shipment_rate incorrect for carrier {carrier_id}: expected {expected_rate}, got {rate}"

    def test_carrier_avg_transit_time_delivered_only(self, db_connection):
        """Verify avg_transit_time_hours_delivered_only excludes non-delivered and NULL transit times."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT carrier_id, avg_transit_time_hours_delivered_only
            FROM marts.mart_carrier_performance
            WHERE avg_transit_time_hours_delivered_only IS NOT NULL
            LIMIT 3
        """)

        for carrier_id, avg_transit in sample:
            # Calculate expected: average of transit_time_hours for DELIVERED shipments with non-NULL transit time
            expected = execute_scalar(conn, db_type, f"""
                SELECT AVG(DATEDIFF('second', SHIPPED_AT, DELIVERED_AT) / 3600.0)
                FROM ORDERS.SHIPMENTS
                WHERE CARRIER_ID = {ph}
                  AND STATUS = 'DELIVERED'
                  AND DELIVERED_AT IS NOT NULL
                  AND SHIPPED_AT IS NOT NULL
            """, [carrier_id])

            if expected is not None:
                assert _approx_equal(float(avg_transit), float(expected), tol=0.1), \
                    f"avg_transit_time_hours_delivered_only incorrect for carrier {carrier_id}: expected {expected}, got {avg_transit}"

    def test_int_order_revenue_summary_totals(self, db_connection):
        """Verify int_order_revenue_summary calculates revenue correctly."""
        conn, db_type = db_connection
        ph = _param_placeholder(db_type)
        sample = execute_query(conn, db_type, """
            SELECT order_id, gross_revenue, shipping_revenue, total_revenue, line_item_count
            FROM intermediate.int_order_revenue_summary
            LIMIT 10
        """)

        for order_id, gross, shipping, total, line_count in sample:
            # Verify total_revenue = gross_revenue + shipping_revenue
            expected_total = float(gross) + float(shipping)
            assert _approx_equal(float(total), expected_total, tol=0.01), \
                f"total_revenue incorrect for order {order_id}: expected {expected_total}, got {total}"

            # Verify gross_revenue matches sum of line_total from order_lines
            expected_gross = execute_scalar(conn, db_type, f"""
                SELECT COALESCE(SUM(LINE_TOTAL), 0)
                FROM ORDERS.ORDER_LINES
                WHERE ORDER_ID = {ph}
            """, [order_id])
            assert _approx_equal(float(gross), float(expected_gross), tol=0.01), \
                f"gross_revenue incorrect for order {order_id}: expected {expected_gross}, got {gross}"

            # Verify line_item_count matches count from order_lines
            expected_count = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM ORDERS.ORDER_LINES
                WHERE ORDER_ID = {ph}
            """, [order_id])
            assert int(line_count) == int(expected_count), \
                f"line_item_count incorrect for order {order_id}: expected {expected_count}, got {line_count}"

    def test_daily_revenue_excludes_cancelled_orders(self, db_connection):
        """Verify cancelled orders are excluded from revenue.

        This test checks that:
        1. Cancelled orders are excluded
        2. Orders with NULL ordered_at are excluded (can't group by date)
        3. Orders without any order_lines are excluded (no revenue to report)
        """
        conn, db_type = db_connection
        # Get total from mart
        mart_total = execute_scalar(conn, db_type, """
            SELECT SUM(order_count)
            FROM marts.mart_daily_revenue
        """)

        # Get expected count: non-cancelled orders with valid ordered_at that have order_lines
        expected = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT o.ORDER_ID)
            FROM ORDERS.ORDERS o
            INNER JOIN ORDERS.ORDER_LINES ol ON o.ORDER_ID = ol.ORDER_ID
            WHERE o.STATUS != 'CANCELLED'
              AND o.ORDERED_AT IS NOT NULL
        """)

        assert int(mart_total) == int(expected), \
            f"order_count should exclude cancelled orders and orders without line items: got {mart_total}, expected {expected}"

    def test_daily_revenue_gross_revenue_calculation(self, db_connection):
        """Verify gross_revenue is calculated from LINE_TOTAL correctly.

        This test verifies the agent correctly handles orphaned order lines
        (lines without matching orders) by excluding them from the calculation.
        """
        conn, db_type = db_connection
        # Get total gross revenue from mart
        mart_gross = execute_scalar(conn, db_type, """
            SELECT SUM(gross_revenue)
            FROM marts.mart_daily_revenue
        """)

        # Calculate expected: LINE_TOTAL sum for non-cancelled orders only
        expected = execute_scalar(conn, db_type, """
            SELECT COALESCE(SUM(ol.LINE_TOTAL), 0)
            FROM ORDERS.ORDER_LINES ol
            INNER JOIN ORDERS.ORDERS o ON ol.ORDER_ID = o.ORDER_ID
            WHERE o.STATUS != 'CANCELLED'
        """)

        assert _approx_equal(float(mart_gross), float(expected), tol=1.0), \
            f"gross_revenue incorrect: got {mart_gross}, expected {expected}. " \
            f"Ensure orphaned order_lines (without matching orders) are excluded."

    def test_daily_revenue_line_item_count(self, db_connection):
        """Verify line_item_count only counts lines with valid orders."""
        conn, db_type = db_connection
        mart_count = execute_scalar(conn, db_type, """
            SELECT SUM(line_item_count)
            FROM marts.mart_daily_revenue
        """)

        # Count only lines that have matching non-cancelled orders
        expected = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM ORDERS.ORDER_LINES ol
            INNER JOIN ORDERS.ORDERS o ON ol.ORDER_ID = o.ORDER_ID
            WHERE o.STATUS != 'CANCELLED'
        """)

        assert int(mart_count) == int(expected), \
            f"line_item_count incorrect: got {mart_count}, expected {expected}"

    def test_daily_revenue_total_equals_gross_plus_shipping(self, db_connection):
        """Verify total_revenue = gross_revenue + shipping_revenue."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_date, gross_revenue, shipping_revenue, total_revenue
            FROM marts.mart_daily_revenue
            WHERE gross_revenue > 0
            LIMIT 10
        """)

        for order_date, gross, shipping, total in result:
            expected_total = float(gross) + float(shipping)
            assert _approx_equal(float(total), expected_total, tol=0.01), \
                f"total_revenue should be gross + shipping for {order_date}: " \
                f"got {total}, expected {expected_total}"

    def test_daily_revenue_avg_order_value(self, db_connection):
        """Verify avg_order_value = total_revenue / order_count."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_date, total_revenue, order_count, avg_order_value
            FROM marts.mart_daily_revenue
            WHERE order_count > 0
            LIMIT 10
        """)

        for order_date, total, count, avg in result:
            expected_avg = float(total) / float(count)
            assert _approx_equal(float(avg), expected_avg, tol=0.01), \
                f"avg_order_value incorrect for {order_date}: got {avg}, expected {expected_avg}"


# ============================================================
# DATA QUALITY TESTS
# ============================================================

class TestDataQuality:
    def test_int_order_lifecycle_grain(self, db_connection):
        """Verify no duplicate order_id."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, COUNT(*) as cnt
            FROM intermediate.int_order_lifecycle
            GROUP BY order_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_id found in int_order_lifecycle: {result[:5]}"

    def test_int_shipment_performance_grain(self, db_connection):
        """Verify no duplicate shipment_id."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT shipment_id, COUNT(*) as cnt
            FROM intermediate.int_shipment_performance
            GROUP BY shipment_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate shipment_id found in int_shipment_performance: {result[:5]}"

    def test_int_order_fulfillment_status_grain(self, db_connection):
        """Verify no duplicate order_id."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, COUNT(*) as cnt
            FROM intermediate.int_order_fulfillment_status
            GROUP BY order_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_id found in int_order_fulfillment_status: {result[:5]}"

    def test_int_order_revenue_summary_grain(self, db_connection):
        """Verify no duplicate order_id."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, COUNT(*) as cnt
            FROM intermediate.int_order_revenue_summary
            GROUP BY order_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_id found in int_order_revenue_summary: {result[:5]}"

    def test_mart_fulfillment_metrics_grain(self, db_connection):
        """Verify no duplicate (warehouse_id, order_date)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT warehouse_id, order_date, COUNT(*) as cnt
            FROM marts.mart_fulfillment_metrics
            GROUP BY warehouse_id, order_date
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate (warehouse_id, order_date) found: {result[:5]}"

    def test_mart_return_analysis_grain(self, db_connection):
        """Verify no duplicate (return_type, return_month)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT return_type, return_month, COUNT(*) as cnt
            FROM marts.mart_return_analysis
            GROUP BY return_type, return_month
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate (return_type, return_month) found: {result[:5]}"

    def test_mart_carrier_performance_grain(self, db_connection):
        """Verify no duplicate carrier_id."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT carrier_id, COUNT(*) as cnt
            FROM marts.mart_carrier_performance
            GROUP BY carrier_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate carrier_id found: {result[:5]}"

    def test_mart_order_status_flow_grain(self, db_connection):
        """Verify no duplicate (old_status, new_status)."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT old_status, new_status, COUNT(*) as cnt
            FROM marts.mart_order_status_flow
            GROUP BY old_status, new_status
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate (old_status, new_status) found: {result[:5]}"

    def test_mart_order_status_flow_no_nulls(self, db_connection):
        """Verify NULL statuses are excluded."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT old_status, new_status
            FROM marts.mart_order_status_flow
            WHERE old_status IS NULL OR new_status IS NULL
        """)
        assert len(result) == 0, f"NULL statuses should be excluded: {result[:5]}"

    def test_mart_daily_revenue_grain(self, db_connection):
        """Verify no duplicate order_date."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_date, COUNT(*) as cnt
            FROM marts.mart_daily_revenue
            GROUP BY order_date
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_date found: {result[:5]}"

    def test_fulfillment_rate_in_valid_range(self, db_connection):
        """Verify fulfillment_rate is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT warehouse_id, order_date, fulfillment_rate
            FROM marts.mart_fulfillment_metrics
            WHERE fulfillment_rate < 0 OR fulfillment_rate > 100
        """)
        assert len(result) == 0, f"fulfillment_rate out of range: {result[:5]}"

    def test_delivery_rate_in_valid_range(self, db_connection):
        """Verify delivery_rate is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT carrier_id, delivery_rate
            FROM marts.mart_carrier_performance
            WHERE delivery_rate < 0 OR delivery_rate > 100
        """)
        assert len(result) == 0, f"delivery_rate out of range: {result[:5]}"

    def test_processing_rate_in_valid_range(self, db_connection):
        """Verify processing_rate is between 0 and 100."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT return_type, return_month, processing_rate
            FROM marts.mart_return_analysis
            WHERE processing_rate < 0 OR processing_rate > 100
        """)
        assert len(result) == 0, f"processing_rate out of range: {result[:5]}"

    def test_fulfillment_pct_in_valid_range(self, db_connection):
        """Verify fulfillment_pct is non-negative."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, fulfillment_pct
            FROM intermediate.int_order_fulfillment_status
            WHERE fulfillment_pct < 0
        """)
        assert len(result) == 0, f"fulfillment_pct is negative: {result[:5]}"

    def test_transit_time_hours_non_negative(self, db_connection):
        """Verify transit_time_hours is non-negative when not NULL."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT shipment_id, transit_time_hours
            FROM intermediate.int_shipment_performance
            WHERE transit_time_hours < 0
        """)
        assert len(result) == 0, f"transit_time_hours is negative: {result[:5]}"

    def test_time_to_ship_hours_non_negative(self, db_connection):
        """Verify time_to_first_ship_hours is non-negative when not NULL."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, time_to_first_ship_hours
            FROM intermediate.int_order_lifecycle
            WHERE time_to_first_ship_hours < 0
        """)
        assert len(result) == 0, f"time_to_first_ship_hours is negative: {result[:5]}"

    def test_time_to_delivery_hours_non_negative(self, db_connection):
        """Verify time_to_delivery_hours is non-negative when not NULL."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, time_to_delivery_hours
            FROM intermediate.int_order_lifecycle
            WHERE time_to_delivery_hours < 0
        """)
        assert len(result) == 0, f"time_to_delivery_hours is negative: {result[:5]}"

    def test_return_month_is_first_day(self, db_connection):
        """Verify return_month is first day of month."""
        conn, db_type = db_connection
        bad_months = execute_query(conn, db_type, """
            SELECT DISTINCT return_month
            FROM marts.mart_return_analysis
            WHERE EXTRACT(DAY FROM CAST(return_month AS DATE)) != 1
        """)
        assert len(bad_months) == 0, \
            f"return_month should be first day of month, found: {bad_months[:5]}"

    def test_avg_processing_time_days_non_negative(self, db_connection):
        """Verify avg_processing_time_days is non-negative when not NULL."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT return_type, return_month, avg_processing_time_days
            FROM marts.mart_return_analysis
            WHERE avg_processing_time_days < 0
        """)
        assert len(result) == 0, f"avg_processing_time_days is negative: {result[:5]}"

    def test_avg_time_in_old_status_hours_non_negative(self, db_connection):
        """Verify avg_time_in_old_status_hours is non-negative when not NULL."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT old_status, new_status, avg_time_in_old_status_hours
            FROM marts.mart_order_status_flow
            WHERE avg_time_in_old_status_hours < 0
        """)
        assert len(result) == 0, f"avg_time_in_old_status_hours is negative: {result[:5]}"
