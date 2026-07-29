"""
Test verifier for order fulfillment metrics with performance analysis task.
Validates dbt models in 4 phases: structure, data quality, business logic, idempotency.
"""

import os
import subprocess
from collections import Counter
from typing import List, Tuple

import pytest

# ============ CONFIGURATION ============

PROJECT_DIR = "/app/dbt_project"
SCHEMA = "fulfillment_analytics"

EXPECTED_ORDER_TYPE_COUNT = 4

VALID_ORDER_TYPES = ['STANDARD', 'SUBSCRIPTION', 'REPLACEMENT', 'EXCHANGE']
VALID_PERFORMANCE_TIERS = ['High Performance', 'Medium Performance', 'Low Performance']
VALID_FULFILLMENT_GRADES = ['Excellent', 'Good', 'Average', 'Poor']

REQUIRED_COLUMNS = {
    'order_type',
    'total_orders',
    'orders_shipped',
    'orders_delivered',
    'fulfillment_rate',
    'delivery_rate',
    'avg_processing_days',
    'min_processing_days',
    'max_processing_days',
    'avg_delivery_days',
    'min_delivery_days',
    'max_delivery_days',
    'total_revenue',
    'avg_order_value',
    'volume_rank',
    'revenue_rank',
    'volume_percentile',
    'revenue_share_pct',
    'efficiency_score',
    'performance_tier',
    'fulfillment_grade',
}

EXPECTED_ORDER_COUNTS = {
    'STANDARD': (1400, 1460),
    'SUBSCRIPTION': (65, 80),
    'REPLACEMENT': (38, 50),
    'EXCHANGE': (33, 45),
}


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
            schema=SCHEMA,
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


# ============ HELPERS ============

def run_cmd(cmd: str, cwd: str = PROJECT_DIR) -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    deps = run_cmd("dbt deps")
    if deps.returncode != 0:
        print("dbt deps failed (may be harmless if no packages).")

    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    # Clean up conflicting relations (DuckDB only)
    if db_type == 'duckdb':
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path, read_only=False)
        try:
            for rel in ("stg_orders", "int_order_fulfillment", "int_order_type_aggregates",
                         "int_order_type_rankings", "fct_fulfillment_by_order_type"):
                for ddl in (
                    f"DROP VIEW IF EXISTS {SCHEMA}.{rel}",
                    f"DROP TABLE IF EXISTS {SCHEMA}.{rel}",
                ):
                    try:
                        conn.execute(ddl)
                    except Exception:
                        pass
        finally:
            conn.close()

    result = run_cmd("dbt run --select +fct_fulfillment_by_order_type --full-refresh")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_fulfillment_metrics() -> List[Tuple]:
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                order_type,
                total_orders,
                orders_shipped,
                orders_delivered,
                fulfillment_rate,
                delivery_rate,
                avg_processing_days,
                min_processing_days,
                max_processing_days,
                avg_delivery_days,
                min_delivery_days,
                max_delivery_days,
                total_revenue,
                avg_order_value,
                volume_rank,
                revenue_rank,
                volume_percentile,
                revenue_share_pct,
                efficiency_score,
                performance_tier,
                fulfillment_grade
            FROM {SCHEMA}.fct_fulfillment_by_order_type
            ORDER BY order_type
        """)
        return rows
    finally:
        conn.close()


def get_table_columns(schema: str, table: str) -> set:
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower('{schema}')
            AND lower(table_name) = lower('{table}')
        """)
        return {c[0].lower() for c in cols}
    finally:
        conn.close()


@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def fulfillment_rows(dbt_run) -> List[Tuple]:
    return query_fulfillment_metrics()


class TestPhase1Structure:

    def test_required_columns_exist(self, dbt_run):
        """Verify all required columns exist in fct_fulfillment_by_order_type."""
        actual_columns = get_table_columns(SCHEMA, 'fct_fulfillment_by_order_type')
        missing = REQUIRED_COLUMNS - actual_columns
        assert not missing, f"Missing required columns: {missing}"

    def test_no_null_values(self, fulfillment_rows):
        """Ensure no NULL values exist in any column of the fulfillment metrics."""
        null_found = []
        for row in fulfillment_rows:
            for i, val in enumerate(row):
                if val is None:
                    null_found.append((row[0], i))
        assert not null_found, f"NULL values found in {len(null_found)} cells"

    def test_unique_order_types(self, fulfillment_rows):
        """Check that each order_type appears exactly once (no duplicates)."""
        order_types = [row[0] for row in fulfillment_rows]
        duplicates = [ot for ot, count in Counter(order_types).items() if count > 1]
        assert not duplicates, f"Duplicate order_types found: {duplicates}"


class TestPhase2DataQuality:

    def test_order_type_count(self, fulfillment_rows):
        """Verify exactly 4 order types are present in the results."""
        actual_count = len(fulfillment_rows)
        assert actual_count == EXPECTED_ORDER_TYPE_COUNT, \
            f"Expected {EXPECTED_ORDER_TYPE_COUNT} order types, got {actual_count}"

    def test_valid_order_types(self, fulfillment_rows):
        """Ensure all order_type values are in the allowed set."""
        invalid = []
        for row in fulfillment_rows:
            if row[0] not in VALID_ORDER_TYPES:
                invalid.append(row[0])
        assert not invalid, f"Invalid order types found: {invalid}"

    def test_valid_performance_tiers(self, fulfillment_rows):
        """Validate that performance_tier values match allowed tier names."""
        invalid = []
        for row in fulfillment_rows:
            tier = row[19]
            if tier not in VALID_PERFORMANCE_TIERS:
                invalid.append((row[0], tier))
        assert not invalid, f"Invalid performance tiers found: {invalid}"

    def test_valid_fulfillment_grades(self, fulfillment_rows):
        """Validate that fulfillment_grade values match allowed grade names."""
        invalid = []
        for row in fulfillment_rows:
            grade = row[20]
            if grade not in VALID_FULFILLMENT_GRADES:
                invalid.append((row[0], grade))
        assert not invalid, f"Invalid fulfillment grades found: {invalid}"

    def test_rate_range(self, fulfillment_rows):
        """Check that fulfillment_rate and delivery_rate are within 0-100 range."""
        invalid = []
        for row in fulfillment_rows:
            fulfillment_rate = float(row[4])
            delivery_rate = float(row[5])
            if fulfillment_rate < 0 or fulfillment_rate > 100:
                invalid.append((row[0], 'fulfillment_rate', fulfillment_rate))
            if delivery_rate < 0 or delivery_rate > 100:
                invalid.append((row[0], 'delivery_rate', delivery_rate))
        assert not invalid, f"Rates outside 0-100 range: {invalid[:5]}"

    def test_positive_time_values(self, fulfillment_rows):
        """Ensure all processing and delivery day values are non-negative."""
        invalid = []
        for row in fulfillment_rows:
            avg_processing = float(row[6])
            min_processing = float(row[7])
            max_processing = float(row[8])
            avg_delivery = float(row[9])
            min_delivery = float(row[10])
            max_delivery = float(row[11])
            if any(v < 0 for v in [avg_processing, min_processing, max_processing, avg_delivery, min_delivery, max_delivery]):
                invalid.append((row[0], 'negative time values'))
        assert not invalid, f"Negative time values found: {invalid}"

    def test_valid_percentile_range(self, fulfillment_rows):
        """Check that volume_percentile values are between 0 and 1."""
        invalid = []
        for row in fulfillment_rows:
            percentile = float(row[16])
            if percentile < 0 or percentile > 1:
                invalid.append((row[0], percentile))
        assert not invalid, f"Invalid percentile values found: {invalid}"


class TestPhase3BusinessLogic:

    def test_revenue_share_sum(self, fulfillment_rows):
        """Verify that revenue_share_pct values sum to approximately 100."""
        total_share = sum(float(row[17]) for row in fulfillment_rows)
        assert abs(total_share - 100) < 0.5, \
            f"Revenue share should sum to ~100, got {total_share}"

    def test_order_counts_by_type(self, fulfillment_rows):
        """Validate total_orders per order_type falls within expected ranges."""
        rows_by_type = {row[0]: row for row in fulfillment_rows}
        for order_type, (min_count, max_count) in EXPECTED_ORDER_COUNTS.items():
            row = rows_by_type.get(order_type)
            assert row is not None, f"Order type {order_type} not found"
            actual = int(row[1])
            assert min_count <= actual <= max_count, \
                f"{order_type}: count {actual} outside range ({min_count}, {max_count})"

    def test_shipped_not_exceed_total(self, fulfillment_rows):
        """Ensure orders_shipped and orders_delivered do not exceed total_orders."""
        violations = []
        for row in fulfillment_rows:
            total = int(row[1])
            shipped = int(row[2])
            delivered = int(row[3])
            if shipped > total:
                violations.append((row[0], 'shipped', shipped, total))
            if delivered > total:
                violations.append((row[0], 'delivered', delivered, total))
        assert not violations, f"Shipped/delivered exceeds total: {violations}"

    def test_fulfillment_rate_calculation(self, fulfillment_rows):
        """Verify fulfillment_rate equals 100 * orders_shipped / total_orders."""
        violations = []
        for row in fulfillment_rows:
            total = int(row[1])
            shipped = int(row[2])
            rate = float(row[4])
            expected_rate = round(100.0 * shipped / total, 4)
            if abs(rate - expected_rate) > 0.1:
                violations.append((row[0], rate, expected_rate))
        assert not violations, f"Fulfillment rate calculation errors: {violations}"

    def test_efficiency_score_calculation(self, fulfillment_rows):
        """Verify efficiency_score matches the weighted formula of rates and processing time."""
        violations = []
        for row in fulfillment_rows:
            fulfillment_rate = float(row[4])
            delivery_rate = float(row[5])
            avg_processing = float(row[6])
            score = float(row[18])
            expected = round((fulfillment_rate / 100.0 * 0.4) + (delivery_rate / 100.0 * 0.4) + ((1.0 / (avg_processing + 1)) * 0.2), 4)
            if abs(score - expected) > 0.01:
                violations.append((row[0], score, expected))
        assert not violations, f"Efficiency score calculation errors: {violations}"

    def test_performance_tier_assignment(self, fulfillment_rows):
        """Validate performance_tier is correctly assigned based on volume_percentile thresholds."""
        violations = []
        for row in fulfillment_rows:
            percentile = float(row[16])
            tier = row[19]
            expected = 'High Performance' if percentile >= 0.66 else 'Medium Performance' if percentile >= 0.33 else 'Low Performance'
            if tier != expected:
                violations.append((row[0], tier, expected, percentile))
        assert not violations, f"Performance tier assignment errors: {violations}"

    def test_fulfillment_grade_assignment(self, fulfillment_rows):
        """Validate fulfillment_grade is correctly assigned based on fulfillment_rate thresholds."""
        violations = []
        for row in fulfillment_rows:
            rate = float(row[4])
            grade = row[20]
            if rate >= 90:
                expected = 'Excellent'
            elif rate >= 70:
                expected = 'Good'
            elif rate >= 50:
                expected = 'Average'
            else:
                expected = 'Poor'
            if grade != expected:
                violations.append((row[0], grade, expected, rate))
        assert not violations, f"Fulfillment grade assignment errors: {violations}"

    def test_min_max_processing_days(self, fulfillment_rows):
        """Ensure min <= avg <= max for processing day values per order type."""
        violations = []
        for row in fulfillment_rows:
            min_days = float(row[7])
            max_days = float(row[8])
            avg_days = float(row[6])
            if min_days > max_days:
                violations.append((row[0], 'min > max', min_days, max_days))
            if avg_days > 0 and (avg_days < min_days or avg_days > max_days):
                violations.append((row[0], 'avg out of range', min_days, avg_days, max_days))
        assert not violations, f"Min/max processing days violations: {violations}"


class TestPhase4Idempotency:

    def test_idempotency(self, fulfillment_rows):
        """Verify that re-running the dbt pipeline produces identical results."""
        rows_before = list(fulfillment_rows)
        run_dbt_pipeline()
        rows_after = query_fulfillment_metrics()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare with float() conversion for Snowflake Decimal compatibility
            for i in range(len(before)):
                val_before = before[i]
                val_after = after[i]
                if isinstance(val_before, str):
                    assert val_before == val_after, f"Row changed after re-run at column {i}: {val_before} -> {val_after}"
                elif val_before is not None:
                    assert abs(float(val_before) - float(val_after)) < 0.001, \
                        f"Row changed after re-run at column {i}: {val_before} -> {val_after}"
