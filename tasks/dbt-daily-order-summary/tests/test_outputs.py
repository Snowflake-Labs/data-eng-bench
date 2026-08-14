"""
Test verifier for Daily Order Summary task.
Validates the daily_order_summary model structure, data quality, and correctness.
"""
import subprocess
import os
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
        # Try password auth first (many Snowflake accounts use password, not private key)
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


# ============ HELPERS ============

def run_cmd(cmd, cwd="/app/dbt_project"):
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt run to build the model."""
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_daily_summary():
    """Query daily_order_summary model and return all rows."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                order_date,
                order_count,
                total_revenue
            FROM daily_analytics.daily_order_summary
            ORDER BY order_date
        """)
        return rows
    finally:
        conn.close()


def get_expected_totals():
    """Calculate expected totals directly from source table with correct filtering."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                COUNT(*) as total_orders,
                ROUND(SUM(GRAND_TOTAL), 2) as total_revenue
            FROM ORDERS.ORDERS
            WHERE STATUS NOT IN ('CANCELLED', 'RETURNED', 'FAILED')
        """)
        return {"total_orders": result[0][0], "total_revenue": float(result[0][1])}
    finally:
        conn.close()


def get_all_orders_count():
    """Get count of ALL orders (without filtering) to detect missing filter."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, "SELECT COUNT(*) FROM ORDERS.ORDERS")
        return result
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    """Fixture that provides daily_order_summary rows after dbt run."""
    return query_daily_summary()


@pytest.fixture(scope="module")
def expected_totals():
    """Fixture that provides expected totals from source data."""
    return get_expected_totals()


# ============ TEST CLASSES ============

class TestStructure:
    """Validate model structure and schema."""

    def test_model_exists(self, dbt_run):
        """Validate the model exists in the correct schema."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = 'daily_analytics'
                AND lower(table_name) = 'daily_order_summary'
            """)
            assert result >= 1, "Model daily_order_summary not found in daily_analytics schema"
        finally:
            conn.close()

    def test_columns_exist(self, dbt_run):
        """Validate required columns exist in daily_order_summary."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'daily_analytics'
                AND lower(table_name) = 'daily_order_summary'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_date", "order_count", "total_revenue"}
            missing = required - col_names
            assert not missing, f"Missing columns in daily_order_summary: {missing}"
        finally:
            conn.close()

    def test_has_data(self, summary_rows):
        """Validate model has data rows."""
        assert len(summary_rows) > 0, "daily_order_summary has no rows"

    def test_no_nulls(self, summary_rows):
        """Validate no NULL values in any column."""
        for row in summary_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL value found in row: {row}"


class TestDataQuality:
    """Validate data quality constraints."""

    def test_unique_dates(self, summary_rows):
        """Validate exactly one row per order_date (no duplicates)."""
        dates = [row[0] for row in summary_rows]
        unique_dates = set(dates)
        assert len(dates) == len(unique_dates), \
            f"Duplicate order_dates found. Total rows: {len(dates)}, Unique dates: {len(unique_dates)}"

    def test_positive_order_counts(self, summary_rows):
        """Validate all order_count values are positive integers."""
        for row in summary_rows:
            order_count = row[1]
            assert isinstance(order_count, int) or order_count == int(order_count), \
                f"order_count should be integer, got {type(order_count)}"
            assert order_count > 0, f"order_count must be positive, got {order_count} for date {row[0]}"

    def test_non_negative_revenue(self, summary_rows):
        """Validate all total_revenue values are non-negative."""
        for row in summary_rows:
            total_revenue = float(row[2])
            assert total_revenue >= 0, f"total_revenue cannot be negative, got {total_revenue} for date {row[0]}"

    def test_revenue_rounded_to_2_decimals(self, summary_rows):
        """Validate total_revenue is rounded to 2 decimal places."""
        for row in summary_rows[:10]:  # Check first 10 rows
            revenue = float(row[2])
            rounded = round(revenue, 2)
            assert abs(revenue - rounded) < 0.001, \
                f"total_revenue {revenue} not rounded to 2 decimals for date {row[0]}"

    def test_dates_sorted_ascending(self, summary_rows):
        """Validate results are sorted by order_date ascending."""
        dates = [row[0] for row in summary_rows]
        assert dates == sorted(dates), "Results should be sorted by order_date ascending"


class TestCorrectness:
    """Validate correctness of aggregation logic including STATUS filtering."""

    def test_total_order_count_matches_filtered_source(self, summary_rows, expected_totals):
        """Validate total order count matches source with STATUS filter applied."""
        actual_total = sum(row[1] for row in summary_rows)
        expected_total = expected_totals["total_orders"]

        # Allow small tolerance for edge cases
        assert actual_total == expected_total, \
            f"Total order count mismatch. Model: {actual_total}, Expected (filtered): {expected_total}. " \
            f"Did you exclude CANCELLED, RETURNED, and FAILED orders?"

    def test_status_filter_applied(self, summary_rows):
        """Verify that the STATUS filter was correctly applied (not all orders included)."""
        actual_total = sum(row[1] for row in summary_rows)
        all_orders = get_all_orders_count()

        assert actual_total < all_orders, \
            f"Model has {actual_total} orders but source has {all_orders}. " \
            f"STATUS filter (exclude CANCELLED, RETURNED, FAILED) may not be applied."

    def test_total_revenue_matches_filtered_source(self, summary_rows, expected_totals):
        """Validate total revenue matches source with STATUS filter applied."""
        actual_total = sum(float(row[2]) for row in summary_rows)
        expected_total = expected_totals["total_revenue"]

        # Allow small tolerance due to rounding at daily level
        tolerance = 1.0  # $1 tolerance for rounding differences
        assert abs(actual_total - expected_total) <= tolerance, \
            f"Total revenue mismatch. Model: {actual_total:.2f}, Expected (filtered): {expected_total:.2f}"


class TestIdempotency:
    """Test that model produces consistent results across reruns."""

    def test_idempotency(self, summary_rows):
        """Test that re-running dbt produces the same results."""
        rows_before = list(summary_rows)
        run_dbt_pipeline()
        rows_after = query_daily_summary()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            assert before == after, \
                f"Row changed after re-run:\nBefore: {before}\nAfter: {after}"
