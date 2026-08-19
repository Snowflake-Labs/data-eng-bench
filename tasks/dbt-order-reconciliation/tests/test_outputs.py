"""Verifier for the DBT Order Reconciliation challenge."""

from __future__ import annotations

import subprocess
import os
from pathlib import Path
import pytest


# ============================================================
# DUAL-BACKEND INFRASTRUCTURE
# ============================================================

def load_snowflake_env():
    """Load Snowflake environment variables from file if available."""
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
    """Load private key from base64-encoded env var."""
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
    """Create a database connection based on DB_TYPE environment variable."""
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
    """Execute a query and return results, handling differences between DuckDB and Snowflake."""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        if params:
            query = query.replace('?', '%s')
            cursor.execute(query, params)
        else:
            cursor.execute(query)
        return cursor.fetchall()
    else:
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value."""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


# ============================================================
# CONSTANTS
# ============================================================

DBT_PROJECT_PATH = Path("/app/dbt_project")

REQUIRED_STAGING_TABLES = [
    "stg_orders",
    "stg_order_lines",
    "stg_order_cancellations",
]

REQUIRED_INTERMEDIATE_TABLES = [
    "int_orders_enriched",
]

REQUIRED_MART_TABLES = [
    "mart_order_totals",
    "mart_revenue_by_source",
    "mart_variance_details",
]

INT_ORDERS_ENRICHED_COLS = {
    "order_id", "order_source", "is_cancelled",
    "subtotal", "grand_total", "tax_total",
    "line_subtotal", "line_tax", "line_count", "has_lines"
}

MART_ORDER_TOTALS_COLS = {
    "order_id", "order_source", "is_cancelled",
    "header_subtotal", "header_grand_total",
    "line_subtotal", "line_count",
    "subtotal_variance", "has_variance",
    "header_tax", "line_tax", "tax_variance", "has_tax_variance"
}

MART_REVENUE_BY_SOURCE_COLS = {
    "order_source", "order_count", "total_revenue",
    "total_items", "avg_order_value"
}

MART_VARIANCE_DETAILS_COLS = {
    "order_id", "order_source",
    "header_subtotal", "line_subtotal", "subtotal_variance", "subtotal_variance_pct",
    "header_tax", "line_tax", "tax_variance", "tax_variance_pct"
}


# ============================================================
# HELPERS
# ============================================================

def _table_exists(conn, db_type, schema: str, table: str) -> bool:
    q = """
    SELECT COUNT(*)
    FROM information_schema.tables
    WHERE LOWER(table_schema) = LOWER(?)
      AND LOWER(table_name) = LOWER(?)
    """
    result = execute_query(conn, db_type, q, [schema, table])
    return result[0][0] > 0


def _rowcount(conn, db_type, schema: str, table: str) -> int:
    result = execute_query(conn, db_type, f"SELECT COUNT(*) FROM {schema}.{table}")
    return int(result[0][0])


def _cols(conn, db_type, schema: str, table: str) -> set:
    rows = execute_query(
        conn, db_type,
        """
        SELECT LOWER(column_name)
        FROM information_schema.columns
        WHERE LOWER(table_schema)=LOWER(?) AND LOWER(table_name)=LOWER(?)
        """,
        [schema, table],
    )
    return {r[0] for r in rows}


def _approx_equal(a: float, b: float, tol: float = 0.01) -> bool:
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    return abs(float(a) - float(b)) <= tol


# ============================================================
# FIXTURES
# ============================================================

@pytest.fixture(scope="session", autouse=True)
def run_dbt():
    """Run dbt commands before tests."""
    assert DBT_PROJECT_PATH.exists(), f"dbt project not found at {DBT_PROJECT_PATH}"
    assert (DBT_PROJECT_PATH / "dbt_project.yml").exists(), "Missing dbt_project.yml"
    assert (DBT_PROJECT_PATH / "profiles.yml").exists(), "Missing profiles.yml"

    result = subprocess.run(
        ["dbt", "run", "--profiles-dir", "."],
        cwd=str(DBT_PROJECT_PATH),
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, f"dbt run failed:\n{result.stdout}\n{result.stderr}"


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
        conn, db_type = db_connection
        assert _table_exists(conn, db_type, "intermediate", table_name), \
            f"Missing intermediate table: intermediate.{table_name}"
        assert _rowcount(conn, db_type, "intermediate", table_name) > 0, \
            f"Intermediate table has no rows: intermediate.{table_name}"

    def test_int_orders_enriched_columns(self, db_connection):
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "intermediate", "int_orders_enriched")
        missing = INT_ORDERS_ENRICHED_COLS - actual
        assert not missing, f"int_orders_enriched missing columns: {missing}"

    def test_int_orders_enriched_grain(self, db_connection):
        """Verify no duplicate order_id in int_orders_enriched."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, COUNT(*) as cnt
            FROM intermediate.int_orders_enriched
            GROUP BY order_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_id found in int_orders_enriched: {result[:5]}"

    def test_int_orders_enriched_has_lines_flag(self, db_connection):
        """Verify has_lines = 1 when line_count > 0."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM intermediate.int_orders_enriched
            WHERE (line_count > 0 AND has_lines != 1)
               OR (line_count = 0 AND has_lines != 0)
        """)
        assert int(result) == 0, "has_lines flag is inconsistent with line_count"


# ============================================================
# MART MODEL TESTS
# ============================================================

class TestMartModels:
    @pytest.mark.parametrize("table_name", REQUIRED_MART_TABLES)
    def test_mart_table_exists(self, db_connection, table_name):
        conn, db_type = db_connection
        assert _table_exists(conn, db_type, "mart", table_name), \
            f"Missing mart table: mart.{table_name}"
        assert _rowcount(conn, db_type, "mart", table_name) > 0, \
            f"Mart table has no rows: mart.{table_name}"

    def test_mart_order_totals_columns(self, db_connection):
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "mart", "mart_order_totals")
        missing = MART_ORDER_TOTALS_COLS - actual
        assert not missing, f"mart_order_totals missing columns: {missing}"

    def test_mart_revenue_by_source_columns(self, db_connection):
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "mart", "mart_revenue_by_source")
        missing = MART_REVENUE_BY_SOURCE_COLS - actual
        assert not missing, f"mart_revenue_by_source missing columns: {missing}"

    def test_mart_variance_details_columns(self, db_connection):
        conn, db_type = db_connection
        actual = _cols(conn, db_type, "mart", "mart_variance_details")
        missing = MART_VARIANCE_DETAILS_COLS - actual
        assert not missing, f"mart_variance_details missing columns: {missing}"


# ============================================================
# DATA QUALITY TESTS - CRITICAL
# ============================================================

class TestDataQuality:
    def test_mart_order_totals_excludes_orphan_lines(self, db_connection):
        """Verify orphaned order_lines (without matching orders) are excluded.

        There are 18 order_lines without matching orders in the source data.
        The mart should only include orders from ORDERS.ORDERS table.
        """
        conn, db_type = db_connection
        mart_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT order_id)
            FROM mart.mart_order_totals
        """)

        source_order_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT ORDER_ID)
            FROM ORDERS.ORDERS
        """)

        assert int(mart_count) == int(source_order_count), \
            f"mart_order_totals should have exactly {source_order_count} orders (one per order in ORDERS table), got {mart_count}"

    def test_mart_order_totals_line_count_excludes_orphans(self, db_connection):
        """Verify line_count only counts lines with valid order references."""
        conn, db_type = db_connection
        mart_total_lines = execute_scalar(conn, db_type, """
            SELECT SUM(line_count)
            FROM mart.mart_order_totals
        """)

        valid_lines = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM ORDERS.ORDER_LINES ol
            INNER JOIN ORDERS.ORDERS o ON ol.ORDER_ID = o.ORDER_ID
        """)

        assert int(mart_total_lines or 0) == int(valid_lines), \
            f"Total line_count should be {valid_lines} (excluding orphan lines), got {mart_total_lines}"

    def test_mart_revenue_by_source_excludes_cancelled(self, db_connection):
        """Verify cancelled orders are excluded from revenue calculations.

        This test ensures the agent uses ORDER_CANCELLATIONS to filter out cancelled orders.
        """
        conn, db_type = db_connection
        mart_total = execute_scalar(conn, db_type, """
            SELECT SUM(order_count)
            FROM mart.mart_revenue_by_source
        """)

        expected = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM ORDERS.ORDERS o
            LEFT JOIN ORDERS.ORDER_CANCELLATIONS oc ON o.ORDER_ID = oc.ORDER_ID
            WHERE oc.ORDER_ID IS NULL
        """)

        assert int(mart_total) == int(expected), \
            f"order_count should exclude cancelled orders: got {mart_total}, expected {expected}"

    def test_mart_revenue_by_source_total_items_excludes_orphans_and_cancelled(self, db_connection):
        """Verify total_items excludes orphan lines AND cancelled order lines."""
        conn, db_type = db_connection
        mart_total_items = execute_scalar(conn, db_type, """
            SELECT SUM(total_items)
            FROM mart.mart_revenue_by_source
        """)

        expected = execute_scalar(conn, db_type, """
            SELECT SUM(ol.QUANTITY_ORDERED)
            FROM ORDERS.ORDER_LINES ol
            INNER JOIN ORDERS.ORDERS o ON ol.ORDER_ID = o.ORDER_ID
            LEFT JOIN ORDERS.ORDER_CANCELLATIONS oc ON o.ORDER_ID = oc.ORDER_ID
            WHERE oc.ORDER_ID IS NULL
        """)

        assert _approx_equal(float(mart_total_items or 0), float(expected or 0), tol=1.0), \
            f"total_items should be {expected} (excluding orphans and cancelled), got {mart_total_items}"

    def test_mart_revenue_by_source_total_revenue(self, db_connection):
        """Verify total_revenue matches source for non-cancelled orders."""
        conn, db_type = db_connection
        mart_total = execute_scalar(conn, db_type, """
            SELECT SUM(total_revenue)
            FROM mart.mart_revenue_by_source
        """)

        expected = execute_scalar(conn, db_type, """
            SELECT SUM(o.GRAND_TOTAL)
            FROM ORDERS.ORDERS o
            LEFT JOIN ORDERS.ORDER_CANCELLATIONS oc ON o.ORDER_ID = oc.ORDER_ID
            WHERE oc.ORDER_ID IS NULL
        """)

        assert _approx_equal(float(mart_total or 0), float(expected or 0), tol=1.0), \
            f"total_revenue should be {expected}, got {mart_total}"

    def test_mart_variance_details_only_has_variances(self, db_connection):
        """Verify mart_variance_details only includes orders with actual variances."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_variance_details
            WHERE subtotal_variance = 0 AND tax_variance = 0
        """)

        assert int(result) == 0, \
            f"mart_variance_details should only contain orders with variances, found {result} rows with no variance"

    def test_mart_variance_details_contains_all_variances(self, db_connection):
        """Verify mart_variance_details contains all orders that have variances."""
        conn, db_type = db_connection
        expected_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE subtotal_variance != 0 OR tax_variance != 0
        """)

        actual_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_variance_details
        """)

        assert int(actual_count) == int(expected_count), \
            f"mart_variance_details should have {expected_count} orders with variances, got {actual_count}"


# ============================================================
# GRAIN TESTS
# ============================================================

class TestGrain:
    def test_mart_order_totals_grain(self, db_connection):
        """Verify no duplicate order_id in mart_order_totals."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, COUNT(*) as cnt
            FROM mart.mart_order_totals
            GROUP BY order_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_id found: {result[:5]}"

    def test_mart_revenue_by_source_grain(self, db_connection):
        """Verify no duplicate order_source in mart_revenue_by_source."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_source, COUNT(*) as cnt
            FROM mart.mart_revenue_by_source
            GROUP BY order_source
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_source found: {result[:5]}"

    def test_mart_variance_details_grain(self, db_connection):
        """Verify no duplicate order_id in mart_variance_details."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, COUNT(*) as cnt
            FROM mart.mart_variance_details
            GROUP BY order_id
            HAVING COUNT(*) > 1
        """)
        assert len(result) == 0, f"Duplicate order_id found in mart_variance_details: {result[:5]}"


# ============================================================
# METRIC CORRECTNESS TESTS
# ============================================================

class TestMetricsCorrectness:
    def test_is_cancelled_flag(self, db_connection):
        """Verify is_cancelled flag matches cancellation records."""
        conn, db_type = db_connection
        mart_cancelled = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE is_cancelled = 1
        """)

        source_cancelled = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT oc.ORDER_ID)
            FROM ORDERS.ORDER_CANCELLATIONS oc
            INNER JOIN ORDERS.ORDERS o ON oc.ORDER_ID = o.ORDER_ID
        """)

        assert int(mart_cancelled) == int(source_cancelled), \
            f"is_cancelled count should be {source_cancelled}, got {mart_cancelled}"

    def test_line_subtotal_calculation(self, db_connection):
        """Verify line_subtotal is SUM of LINE_TOTAL for each order."""
        conn, db_type = db_connection
        sample = execute_query(conn, db_type, """
            SELECT order_id, line_subtotal
            FROM mart.mart_order_totals
            WHERE line_count > 0
            LIMIT 5
        """)

        for order_id, line_subtotal in sample:
            expected = execute_scalar(conn, db_type, """
                SELECT SUM(LINE_TOTAL)
                FROM ORDERS.ORDER_LINES
                WHERE ORDER_ID = ?
            """, [order_id])

            assert _approx_equal(float(line_subtotal or 0), float(expected or 0), tol=0.01), \
                f"line_subtotal incorrect for order {order_id}: got {line_subtotal}, expected {expected}"

    def test_line_tax_calculation(self, db_connection):
        """Verify line_tax is SUM of TAX_AMOUNT for each order."""
        conn, db_type = db_connection
        sample = execute_query(conn, db_type, """
            SELECT order_id, line_tax
            FROM mart.mart_order_totals
            WHERE line_count > 0
            LIMIT 5
        """)

        for order_id, line_tax in sample:
            expected = execute_scalar(conn, db_type, """
                SELECT SUM(TAX_AMOUNT)
                FROM ORDERS.ORDER_LINES
                WHERE ORDER_ID = ?
            """, [order_id])

            assert _approx_equal(float(line_tax or 0), float(expected or 0), tol=0.01), \
                f"line_tax incorrect for order {order_id}: got {line_tax}, expected {expected}"

    def test_subtotal_variance_calculation(self, db_connection):
        """Verify subtotal_variance = header_subtotal - line_subtotal."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, header_subtotal, line_subtotal, subtotal_variance
            FROM mart.mart_order_totals
            WHERE line_count > 0
            LIMIT 10
        """)

        for order_id, header, line, variance in result:
            expected_variance = float(header or 0) - float(line or 0)
            assert _approx_equal(float(variance or 0), expected_variance, tol=0.01), \
                f"subtotal_variance incorrect for order {order_id}"

    def test_tax_variance_calculation(self, db_connection):
        """Verify tax_variance = header_tax - line_tax."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, header_tax, line_tax, tax_variance
            FROM mart.mart_order_totals
            WHERE line_count > 0
            LIMIT 10
        """)

        for order_id, header_tax, line_tax, variance in result:
            expected_variance = float(header_tax or 0) - float(line_tax or 0)
            assert _approx_equal(float(variance or 0), expected_variance, tol=0.01), \
                f"tax_variance incorrect for order {order_id}"

    def test_has_variance_flag(self, db_connection):
        """Verify has_variance = 1 when subtotal_variance != 0."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE (subtotal_variance != 0 AND has_variance != 1)
               OR (subtotal_variance = 0 AND has_variance != 0)
        """)

        assert int(result) == 0, "has_variance flag is inconsistent with subtotal_variance"

    def test_has_tax_variance_flag(self, db_connection):
        """Verify has_tax_variance = 1 when tax_variance != 0."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE (tax_variance != 0 AND has_tax_variance != 1)
               OR (tax_variance = 0 AND has_tax_variance != 0)
        """)

        assert int(result) == 0, "has_tax_variance flag is inconsistent with tax_variance"

    def test_avg_order_value_calculation(self, db_connection):
        """Verify avg_order_value = total_revenue / order_count."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_source, total_revenue, order_count, avg_order_value
            FROM mart.mart_revenue_by_source
            WHERE order_count > 0
        """)

        for source, revenue, count, avg in result:
            expected_avg = float(revenue) / float(count)
            assert _approx_equal(float(avg), expected_avg, tol=0.01), \
                f"avg_order_value incorrect for {source}: got {avg}, expected {expected_avg}"

    def test_orders_with_no_lines_have_zero_line_subtotal(self, db_connection):
        """Verify orders without lines have line_subtotal = 0 and line_count = 0."""
        conn, db_type = db_connection
        orders_without_lines = execute_query(conn, db_type, """
            SELECT o.ORDER_ID
            FROM ORDERS.ORDERS o
            LEFT JOIN ORDERS.ORDER_LINES ol ON o.ORDER_ID = ol.ORDER_ID
            WHERE ol.ORDER_ID IS NULL
        """)

        if len(orders_without_lines) > 0:
            sample_order = orders_without_lines[0][0]
            result = execute_query(conn, db_type, """
                SELECT line_count, line_subtotal
                FROM mart.mart_order_totals
                WHERE order_id = ?
            """, [sample_order])

            assert len(result) > 0, f"Order {sample_order} not found in mart"
            line_count, line_subtotal = result[0]
            assert int(line_count or 0) == 0, f"Orders without lines should have line_count = 0"
            assert float(line_subtotal or 0) == 0, f"Orders without lines should have line_subtotal = 0"

    def test_variance_pct_calculation(self, db_connection):
        """Verify variance percentage calculations in mart_variance_details."""
        conn, db_type = db_connection
        result = execute_query(conn, db_type, """
            SELECT order_id, header_subtotal, subtotal_variance, subtotal_variance_pct
            FROM mart.mart_variance_details
            WHERE header_subtotal > 0
            LIMIT 5
        """)

        for order_id, header, variance, pct in result:
            expected_pct = (float(variance) / float(header)) * 100
            assert _approx_equal(float(pct or 0), expected_pct, tol=0.1), \
                f"subtotal_variance_pct incorrect for order {order_id}: got {pct}, expected {expected_pct}"

    def test_variance_pct_zero_division(self, db_connection):
        """Verify variance_pct is 0 when header value is 0."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_variance_details
            WHERE header_subtotal = 0 AND subtotal_variance_pct != 0
        """)

        assert int(result) == 0, "subtotal_variance_pct should be 0 when header_subtotal is 0"

        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_variance_details
            WHERE header_tax = 0 AND tax_variance_pct != 0
        """)

        assert int(result) == 0, "tax_variance_pct should be 0 when header_tax is 0"


# ============================================================
# STRICTER VALIDATION TESTS
# ============================================================

class TestStricterValidations:
    """Stricter tests for rate bounds, variance consistency, scope, cancellation filtering, and NULL handling."""

    # ----------------------------------------------------------
    # 1. Rate/ratio columns bounded (no infinity / NaN)
    # ----------------------------------------------------------

    def test_subtotal_variance_pct_is_finite(self, db_connection):
        """Verify subtotal_variance_pct contains no infinity or NaN values."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, """
            SELECT order_id, subtotal_variance_pct
            FROM mart.mart_variance_details
        """)
        import math
        for order_id, pct in rows:
            val = float(pct)
            assert math.isfinite(val), (
                f"subtotal_variance_pct is not finite for order {order_id}: {val}"
            )

    def test_tax_variance_pct_is_finite(self, db_connection):
        """Verify tax_variance_pct contains no infinity or NaN values."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, """
            SELECT order_id, tax_variance_pct
            FROM mart.mart_variance_details
        """)
        import math
        for order_id, pct in rows:
            val = float(pct)
            assert math.isfinite(val), (
                f"tax_variance_pct is not finite for order {order_id}: {val}"
            )

    def test_avg_order_value_is_finite(self, db_connection):
        """Verify avg_order_value in mart_revenue_by_source is finite (no infinity/NaN)."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, """
            SELECT order_source, avg_order_value
            FROM mart.mart_revenue_by_source
        """)
        import math
        for source, avg in rows:
            val = float(avg)
            assert math.isfinite(val), (
                f"avg_order_value is not finite for source '{source}': {val}"
            )

    # ----------------------------------------------------------
    # 2. Variance consistency (has_variance IFF variance != 0)
    # ----------------------------------------------------------

    def test_has_variance_iff_subtotal_variance_nonzero(self, db_connection):
        """Strictly verify has_variance = 1 IFF subtotal_variance != 0, covering every row."""
        conn, db_type = db_connection
        # Count rows where has_variance = 1 but subtotal_variance = 0
        mismatch_true = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_variance = 1 AND subtotal_variance = 0
        """)
        assert int(mismatch_true) == 0, (
            f"has_variance=1 but subtotal_variance=0 for {mismatch_true} rows"
        )
        # Count rows where has_variance = 0 but subtotal_variance != 0
        mismatch_false = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_variance = 0 AND subtotal_variance != 0
        """)
        assert int(mismatch_false) == 0, (
            f"has_variance=0 but subtotal_variance!=0 for {mismatch_false} rows"
        )
        # Also verify only valid boolean values exist (0 or 1)
        invalid_vals = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_variance NOT IN (0, 1)
        """)
        assert int(invalid_vals) == 0, (
            f"has_variance contains values other than 0 or 1 in {invalid_vals} rows"
        )

    def test_has_tax_variance_iff_tax_variance_nonzero(self, db_connection):
        """Strictly verify has_tax_variance = 1 IFF tax_variance != 0, covering every row."""
        conn, db_type = db_connection
        # Count rows where has_tax_variance = 1 but tax_variance = 0
        mismatch_true = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_tax_variance = 1 AND tax_variance = 0
        """)
        assert int(mismatch_true) == 0, (
            f"has_tax_variance=1 but tax_variance=0 for {mismatch_true} rows"
        )
        # Count rows where has_tax_variance = 0 but tax_variance != 0
        mismatch_false = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_tax_variance = 0 AND tax_variance != 0
        """)
        assert int(mismatch_false) == 0, (
            f"has_tax_variance=0 but tax_variance!=0 for {mismatch_false} rows"
        )
        # Also verify only valid boolean values exist (0 or 1)
        invalid_vals = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_tax_variance NOT IN (0, 1)
        """)
        assert int(invalid_vals) == 0, (
            f"has_tax_variance contains values other than 0 or 1 in {invalid_vals} rows"
        )

    # ----------------------------------------------------------
    # 3. mart_variance_details scope: all rows have non-zero
    #    variance AND row count matches mart_order_totals
    # ----------------------------------------------------------

    def test_variance_details_all_rows_have_nonzero_variance(self, db_connection):
        """Verify every row in mart_variance_details has at least one non-zero variance."""
        conn, db_type = db_connection
        bad_rows = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_variance_details
            WHERE subtotal_variance = 0 AND tax_variance = 0
        """)
        assert int(bad_rows) == 0, (
            f"mart_variance_details contains {bad_rows} rows where both "
            f"subtotal_variance and tax_variance are zero"
        )

    def test_variance_details_row_count_matches_order_totals(self, db_connection):
        """Verify mart_variance_details row count equals count of rows with variance in mart_order_totals."""
        conn, db_type = db_connection
        variance_details_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_variance_details
        """)
        order_totals_with_variance = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE subtotal_variance != 0 OR tax_variance != 0
        """)
        assert int(variance_details_count) == int(order_totals_with_variance), (
            f"mart_variance_details has {variance_details_count} rows but "
            f"mart_order_totals has {order_totals_with_variance} rows with non-zero variance"
        )

    # ----------------------------------------------------------
    # 4. mart_revenue_by_source excludes cancelled orders
    #    (per-source verification against source tables)
    # ----------------------------------------------------------

    def test_revenue_by_source_order_count_equals_noncancelled(self, db_connection):
        """Verify total order_count in mart_revenue_by_source equals count of non-cancelled orders from source."""
        conn, db_type = db_connection
        mart_total = execute_scalar(conn, db_type, """
            SELECT SUM(order_count)
            FROM mart.mart_revenue_by_source
        """)
        source_noncancelled = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM ORDERS.ORDERS o
            LEFT JOIN ORDERS.ORDER_CANCELLATIONS oc ON o.ORDER_ID = oc.ORDER_ID
            WHERE oc.ORDER_ID IS NULL
        """)
        assert int(mart_total) == int(source_noncancelled), (
            f"Total order_count across all sources is {mart_total} but expected "
            f"{source_noncancelled} non-cancelled orders from source"
        )

    def test_revenue_by_source_per_source_count_matches(self, db_connection):
        """Verify order_count per order_source matches non-cancelled counts from source."""
        conn, db_type = db_connection
        mart_rows = execute_query(conn, db_type, """
            SELECT order_source, order_count
            FROM mart.mart_revenue_by_source
        """)
        for source, mart_count in mart_rows:
            # Skip NULL/None sources - these aggregate orders with missing order_source
            if source is None or str(source).strip().lower() in ('none', ''):
                continue
            expected = execute_scalar(conn, db_type, """
                SELECT COUNT(*)
                FROM ORDERS.ORDERS o
                LEFT JOIN ORDERS.ORDER_CANCELLATIONS oc ON o.ORDER_ID = oc.ORDER_ID
                WHERE oc.ORDER_ID IS NULL AND LOWER(o.ORDER_SOURCE) = LOWER(?)
            """, [source])
            assert int(mart_count) == int(expected), (
                f"order_count for source '{source}' is {mart_count} but expected "
                f"{expected} non-cancelled orders"
            )

    # ----------------------------------------------------------
    # 5. NULL handling: key computed columns must not be NULL
    # ----------------------------------------------------------

    def test_no_nulls_in_subtotal_variance(self, db_connection):
        """Verify subtotal_variance has no NULL values in mart_order_totals."""
        conn, db_type = db_connection
        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE subtotal_variance IS NULL
        """)
        assert int(null_count) == 0, (
            f"subtotal_variance is NULL in {null_count} rows of mart_order_totals"
        )

    def test_no_nulls_in_has_variance(self, db_connection):
        """Verify has_variance has no NULL values in mart_order_totals."""
        conn, db_type = db_connection
        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_variance IS NULL
        """)
        assert int(null_count) == 0, (
            f"has_variance is NULL in {null_count} rows of mart_order_totals"
        )

    def test_no_nulls_in_tax_variance(self, db_connection):
        """Verify tax_variance has no NULL values in mart_order_totals."""
        conn, db_type = db_connection
        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE tax_variance IS NULL
        """)
        assert int(null_count) == 0, (
            f"tax_variance is NULL in {null_count} rows of mart_order_totals"
        )

    def test_no_nulls_in_has_tax_variance(self, db_connection):
        """Verify has_tax_variance has no NULL values in mart_order_totals."""
        conn, db_type = db_connection
        null_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM mart.mart_order_totals
            WHERE has_tax_variance IS NULL
        """)
        assert int(null_count) == 0, (
            f"has_tax_variance is NULL in {null_count} rows of mart_order_totals"
        )
