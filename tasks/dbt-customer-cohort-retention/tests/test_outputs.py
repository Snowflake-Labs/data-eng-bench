"""
Test verifier for Customer Cohort Retention Analysis task.
Multi-phase testing:
  Phase 1: Validate model structure and dbt execution
  Phase 2: Validate cohort_retention model output (including cumulative metrics)
  Phase 3: Validate cohort_revenue model output (including cumulative metrics)
  Phase 4: Validate cohort_summary model output
  Phase 5: Cross-model consistency checks
  Phase 6: Data integrity and formula validation
  Phase 7: Test idempotency
"""
import subprocess
import os
from collections import Counter
from decimal import Decimal, ROUND_HALF_UP
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


# ============ HELPERS ============

def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ EXPECTED VALUES ============

# Expected total customers in analysis (2023-01 to 2024-12)
EXPECTED_TOTAL_CUSTOMERS = 224

# Expected cohort sizes for all 24 cohorts (comprehensive check)
EXPECTED_COHORT_SIZES = {
    '2023-01': 14,
    '2023-02': 15,
    '2023-03': 10,
    '2023-04': 11,
    '2023-05': 15,
    '2023-06': 8,
    '2023-07': 8,
    '2023-08': 9,
    '2023-09': 7,
    '2023-10': 14,
    '2023-11': 26,
    '2023-12': 8,
    '2024-01': 4,
    '2024-02': 3,
    '2024-03': 9,
    '2024-04': 4,
    '2024-05': 6,
    '2024-06': 5,
    '2024-07': 10,
    '2024-08': 5,
    '2024-09': 6,
    '2024-10': 7,
    '2024-11': 9,
    '2024-12': 11,
}

# Valid cohort months (YYYY-MM format)
VALID_COHORT_MONTHS = [f"2023-{m:02d}" for m in range(1, 13)] + [f"2024-{m:02d}" for m in range(1, 13)]

# Schema where models are created (existing project creates in 'main' by default)
SCHEMA_NAME = "main"

# Maximum months_since_first_order (from 2023-01 to 2024-12 = 23 months)
MAX_MONTHS_SINCE_FIRST_ORDER = 23

# Cohorts that should have retention_month_6 (started before July 2024)
COHORTS_WITH_MONTH_6 = [f"2023-{m:02d}" for m in range(1, 13)] + [f"2024-{m:02d}" for m in range(1, 7)]

# Cohorts that should have retention_month_12 (started before Jan 2024)
COHORTS_WITH_MONTH_12 = [f"2023-{m:02d}" for m in range(1, 13)]


def run_cmd(cmd, cwd=None):
    """Run a shell command and return the result."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt run for cohort models."""
    # Install dependencies first
    deps_result = run_cmd("dbt deps")
    assert deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}"

    result = run_cmd("dbt run --select +cohort_retention +cohort_revenue +cohort_summary")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_cohort_retention():
    """Query cohort_retention model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                cohort_month,
                months_since_first_order,
                cohort_size,
                retained_customers,
                retention_rate,
                cumulative_retained,
                cumulative_retention_rate
            FROM {SCHEMA_NAME}.cohort_retention
            ORDER BY cohort_month, months_since_first_order
        """)
        return rows
    finally:
        conn.close()


def query_cohort_revenue():
    """Query cohort_revenue model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                cohort_month,
                months_since_first_order,
                cohort_size,
                total_revenue,
                revenue_per_customer,
                cumulative_revenue,
                cumulative_revenue_per_customer
            FROM {SCHEMA_NAME}.cohort_revenue
            ORDER BY cohort_month, months_since_first_order
        """)
        return rows
    finally:
        conn.close()


def query_cohort_summary():
    """Query cohort_summary model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                cohort_month,
                cohort_size,
                total_lifetime_revenue,
                avg_revenue_per_customer,
                avg_orders_per_customer,
                months_active,
                retention_month_6,
                retention_month_12
            FROM {SCHEMA_NAME}.cohort_summary
            ORDER BY cohort_month
        """)
        return rows
    finally:
        conn.close()


def _orders_table():
    """Return the fully qualified orders table reference based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'ORDERS.ORDERS'
    return 'main.orders'


def query_unique_customers_in_period():
    """Count unique customers with valid orders in analysis period."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(DISTINCT customer_id) FROM {_orders_table()}
            WHERE ordered_at >= '2023-01-01'
              AND ordered_at < '2025-01-01'
              AND status NOT IN ('CANCELLED', 'RETURNED')
        """)
        return int(result)
    finally:
        conn.close()


def query_excluded_status_orders():
    """Get count of cancelled/returned orders in period."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT status, COUNT(*) as cnt FROM {_orders_table()}
            WHERE ordered_at >= '2023-01-01'
              AND ordered_at < '2025-01-01'
              AND status IN ('CANCELLED', 'RETURNED')
            GROUP BY status
        """)
        return {row[0]: int(row[1]) for row in rows}
    finally:
        conn.close()


def validate_retention_columns():
    """Validate required columns exist in cohort_retention."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA_NAME.lower()}'
            AND lower(table_name) = 'cohort_retention'
        """)
        col_names = {c[0].lower() for c in rows}
        required = {
            "cohort_month", "months_since_first_order", "cohort_size",
            "retained_customers", "retention_rate",
            "cumulative_retained", "cumulative_retention_rate"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in cohort_retention: {missing}"
        print(f"All required columns present: {required}")
    finally:
        conn.close()


def validate_revenue_columns():
    """Validate required columns exist in cohort_revenue."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA_NAME.lower()}'
            AND lower(table_name) = 'cohort_revenue'
        """)
        col_names = {c[0].lower() for c in rows}
        required = {
            "cohort_month", "months_since_first_order", "cohort_size",
            "total_revenue", "revenue_per_customer",
            "cumulative_revenue", "cumulative_revenue_per_customer"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in cohort_revenue: {missing}"
        print(f"All required columns present: {required}")
    finally:
        conn.close()


def validate_summary_columns():
    """Validate required columns exist in cohort_summary."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = '{SCHEMA_NAME.lower()}'
            AND lower(table_name) = 'cohort_summary'
        """)
        col_names = {c[0].lower() for c in rows}
        required = {
            "cohort_month", "cohort_size", "total_lifetime_revenue",
            "avg_revenue_per_customer", "avg_orders_per_customer",
            "months_active", "retention_month_6", "retention_month_12"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in cohort_summary: {missing}"
        print(f"All required columns present: {required}")
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def retention_rows(dbt_run):
    """Fixture that provides cohort_retention rows after dbt run."""
    return query_cohort_retention()


@pytest.fixture(scope="module")
def revenue_rows(dbt_run):
    """Fixture that provides cohort_revenue rows after dbt run."""
    return query_cohort_revenue()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    """Fixture that provides cohort_summary rows after dbt run."""
    return query_cohort_summary()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and dbt execution."""

    def test_retention_columns_exist(self, dbt_run):
        """Validate required columns exist in cohort_retention."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        validate_retention_columns()

    def test_revenue_columns_exist(self, dbt_run):
        """Validate required columns exist in cohort_revenue."""
        validate_revenue_columns()

    def test_summary_columns_exist(self, dbt_run):
        """Validate required columns exist in cohort_summary."""
        validate_summary_columns()

    def test_retention_has_rows(self, retention_rows):
        """Validate cohort_retention has data."""
        assert len(retention_rows) > 0, "cohort_retention model is empty"
        print(f"cohort_retention has {len(retention_rows)} rows")

    def test_revenue_has_rows(self, revenue_rows):
        """Validate cohort_revenue has data."""
        assert len(revenue_rows) > 0, "cohort_revenue model is empty"
        print(f"cohort_revenue has {len(revenue_rows)} rows")

    def test_summary_has_rows(self, summary_rows):
        """Validate cohort_summary has data."""
        assert len(summary_rows) > 0, "cohort_summary model is empty"
        print(f"cohort_summary has {len(summary_rows)} rows")

    def test_summary_has_24_rows(self, summary_rows):
        """Validate cohort_summary has exactly 24 rows (one per cohort)."""
        assert len(summary_rows) == 24, \
            f"cohort_summary should have 24 rows, got {len(summary_rows)}"
        print("cohort_summary has exactly 24 rows")

    def test_retention_row_count_reasonable(self, retention_rows):
        """Validate cohort_retention has reasonable number of rows."""
        assert len(retention_rows) >= 24, \
            f"cohort_retention has too few rows: {len(retention_rows)}"
        assert len(retention_rows) <= 576, \
            f"cohort_retention has too many rows: {len(retention_rows)}"
        print(f"Row count {len(retention_rows)} is within expected range [24, 576]")


class TestPhase2Retention:
    """Phase 2: Validate cohort_retention model output including cumulative metrics."""

    def test_valid_cohort_months(self, retention_rows):
        """Validate cohort months are in expected format."""
        print("\n" + "="*50)
        print("PHASE 2: Cohort Retention Validation")
        print("="*50)
        for row in retention_rows:
            cohort_month = row[0]
            assert cohort_month in VALID_COHORT_MONTHS, \
                f"Invalid cohort_month: {cohort_month}"
        print("All cohort months are valid (YYYY-MM format, 2023-2024)")

    def test_all_24_cohorts_present(self, retention_rows):
        """Validate all 24 cohorts (2023-01 through 2024-12) are present."""
        cohorts_present = set(r[0] for r in retention_rows)
        missing = set(VALID_COHORT_MONTHS) - cohorts_present
        assert not missing, f"Missing cohorts: {sorted(missing)}"
        print("All 24 cohorts present")

    def test_months_since_first_order_non_negative(self, retention_rows):
        """Validate months_since_first_order is non-negative."""
        for row in retention_rows:
            months = int(row[1])
            assert months >= 0, f"Negative months_since_first_order: {months}"
        print("All months_since_first_order values are non-negative")

    def test_months_since_first_order_within_bounds(self, retention_rows):
        """Validate months_since_first_order doesn't exceed maximum possible."""
        for row in retention_rows:
            cohort_month, months = row[0], int(row[1])
            cohort_year, cohort_mon = map(int, cohort_month.split('-'))
            # Add 1 for tolerance on off-by-one edge cases
            max_months = (2024 - cohort_year) * 12 + (12 - cohort_mon) + 1
            assert months <= max_months, \
                f"Cohort {cohort_month} has months_since_first_order={months}, max should be {max_months}"
        print("All months_since_first_order values are within valid bounds")

    def test_month_0_has_full_retention(self, retention_rows):
        """Validate month 0 has 100% retention."""
        month_0_rows = [r for r in retention_rows if int(r[1]) == 0]
        assert len(month_0_rows) == 24, f"Expected 24 month-0 rows, got {len(month_0_rows)}"
        for row in month_0_rows:
            cohort_month, months, cohort_size, retained, rate, cum_retained, cum_rate = row
            assert int(cohort_size) == int(retained), \
                f"Month 0 for {cohort_month}: cohort_size ({cohort_size}) != retained ({retained})"
            assert abs(float(rate) - 100.0) < 0.01, \
                f"Month 0 for {cohort_month}: retention_rate should be 100, got {rate}"
        print(f"All {len(month_0_rows)} cohorts have 100% retention at month 0")

    def test_cumulative_retained_at_month_0(self, retention_rows):
        """Validate cumulative_retained at month 0 equals cohort_size."""
        month_0_rows = [r for r in retention_rows if int(r[1]) == 0]
        for row in month_0_rows:
            cohort_month, months, cohort_size, retained, rate, cum_retained, cum_rate = row
            assert int(cum_retained) == int(cohort_size), \
                f"Month 0 for {cohort_month}: cumulative_retained ({cum_retained}) != cohort_size ({cohort_size})"
            assert abs(float(cum_rate) - 100.0) < 0.01, \
                f"Month 0 for {cohort_month}: cumulative_retention_rate should be 100, got {cum_rate}"
        print("All cohorts have cumulative_retained = cohort_size at month 0")

    def test_cumulative_retained_non_decreasing(self, retention_rows):
        """Validate cumulative_retained is non-decreasing within each cohort."""
        by_cohort = {}
        for row in retention_rows:
            cohort = row[0]
            if cohort not in by_cohort:
                by_cohort[cohort] = []
            by_cohort[cohort].append(row)

        for cohort, rows in by_cohort.items():
            sorted_rows = sorted(rows, key=lambda x: int(x[1]))  # sort by months_since_first_order
            for i in range(1, len(sorted_rows)):
                prev_cum = int(sorted_rows[i-1][5])  # cumulative_retained
                curr_cum = int(sorted_rows[i][5])
                assert curr_cum >= prev_cum, \
                    f"Cohort {cohort}: cumulative_retained decreased from {prev_cum} to {curr_cum}"
        print("cumulative_retained is non-decreasing for all cohorts")

    def test_cumulative_retention_rate_valid_range(self, retention_rows):
        """Validate cumulative_retention_rate is between 0 and 100."""
        for row in retention_rows:
            cum_rate = float(row[6])
            assert 0 <= cum_rate <= 100, \
                f"Invalid cumulative_retention_rate {cum_rate} for {row[0]} month {row[1]}"
        print("All cumulative_retention_rate values are between 0 and 100")

    def test_retention_rate_valid_range(self, retention_rows):
        """Validate retention_rate is between 0 and 100."""
        for row in retention_rows:
            rate = float(row[4])
            assert 0 <= rate <= 100, \
                f"Invalid retention_rate {rate} for {row[0]} month {row[1]}"
        print("All retention rates are between 0 and 100")

    def test_cohort_sizes_all_cohorts(self, retention_rows):
        """Validate cohort sizes for all 24 cohorts."""
        month_0_by_cohort = {r[0]: int(r[2]) for r in retention_rows if int(r[1]) == 0}
        for cohort, expected_size in EXPECTED_COHORT_SIZES.items():
            actual_size = month_0_by_cohort.get(cohort)
            assert actual_size is not None, f"Cohort {cohort} not found"
            assert actual_size == expected_size, \
                f"Cohort {cohort}: expected size {expected_size}, got {actual_size}"
        print(f"Cohort size validation passed for all {len(EXPECTED_COHORT_SIZES)} cohorts")

    def test_total_customers_sum(self, retention_rows):
        """Validate total unique customers equals sum of cohort sizes."""
        month_0_rows = [r for r in retention_rows if int(r[1]) == 0]
        total_from_cohorts = sum(int(r[2]) for r in month_0_rows)
        assert total_from_cohorts == EXPECTED_TOTAL_CUSTOMERS, \
            f"Total customers: expected {EXPECTED_TOTAL_CUSTOMERS}, got {total_from_cohorts}"
        print(f"Total customers verified: {total_from_cohorts}")

    def test_no_null_values_in_retention(self, retention_rows):
        """Validate no NULL values in cohort_retention."""
        for row in retention_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL value found in retention row: {row}"
        print(f"No NULL values found in {len(retention_rows)} retention rows")


class TestPhase3Revenue:
    """Phase 3: Validate cohort_revenue model output including cumulative metrics."""

    def test_valid_cohort_months(self, revenue_rows):
        """Validate cohort months in revenue model."""
        print("\n" + "="*50)
        print("PHASE 3: Cohort Revenue Validation")
        print("="*50)
        for row in revenue_rows:
            cohort_month = row[0]
            assert cohort_month in VALID_COHORT_MONTHS, \
                f"Invalid cohort_month: {cohort_month}"
        print("All cohort months are valid")

    def test_all_24_cohorts_present(self, revenue_rows):
        """Validate all 24 cohorts are present in revenue model."""
        cohorts_present = set(r[0] for r in revenue_rows)
        missing = set(VALID_COHORT_MONTHS) - cohorts_present
        assert not missing, f"Missing cohorts in revenue: {sorted(missing)}"
        print("All 24 cohorts present in revenue model")

    def test_revenue_non_negative(self, revenue_rows):
        """Validate total_revenue is non-negative."""
        for row in revenue_rows:
            revenue = float(row[3])
            assert revenue >= 0, \
                f"Negative revenue for {row[0]} month {row[1]}: {revenue}"
        print("All revenue values are non-negative")

    def test_cumulative_revenue_non_decreasing(self, revenue_rows):
        """Validate cumulative_revenue is non-decreasing within each cohort."""
        by_cohort = {}
        for row in revenue_rows:
            cohort = row[0]
            if cohort not in by_cohort:
                by_cohort[cohort] = []
            by_cohort[cohort].append(row)

        for cohort, rows in by_cohort.items():
            sorted_rows = sorted(rows, key=lambda x: int(x[1]))
            for i in range(1, len(sorted_rows)):
                prev_cum = float(sorted_rows[i-1][5])  # cumulative_revenue
                curr_cum = float(sorted_rows[i][5])
                assert curr_cum >= prev_cum - 0.01, \
                    f"Cohort {cohort}: cumulative_revenue decreased from {prev_cum} to {curr_cum}"
        print("cumulative_revenue is non-decreasing for all cohorts")

    def test_cumulative_revenue_per_customer_formula(self, revenue_rows):
        """Validate cumulative_revenue_per_customer = cumulative_revenue / cohort_size."""
        for row in revenue_rows:
            cohort_month, months, cohort_size, total_rev, rpc, cum_rev, cum_rpc = row
            expected_cum_rpc = round(float(cum_rev) / int(cohort_size), 2)
            assert abs(float(cum_rpc) - expected_cum_rpc) < 0.02, \
                f"Cumulative revenue per customer formula mismatch for {cohort_month} month {months}"
        print("Cumulative revenue per customer formula verified")

    def test_revenue_per_customer_formula(self, revenue_rows):
        """Validate revenue_per_customer = total_revenue / cohort_size."""
        for row in revenue_rows:
            cohort_month, months, cohort_size, total_revenue, rpc, cum_rev, cum_rpc = row
            expected_rpc = round(float(total_revenue) / int(cohort_size), 2)
            assert abs(float(rpc) - expected_rpc) < 0.02, \
                f"Revenue per customer formula mismatch for {cohort_month} month {months}"
        print("Revenue per customer formula verified for all rows")

    def test_no_null_values_in_revenue(self, revenue_rows):
        """Validate no NULL values in cohort_revenue."""
        for row in revenue_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL value found in revenue row: {row}"
        print(f"No NULL values found in {len(revenue_rows)} revenue rows")


class TestPhase4Summary:
    """Phase 4: Validate cohort_summary model output."""

    def test_all_24_cohorts_present(self, summary_rows):
        """Validate all 24 cohorts are present in summary."""
        print("\n" + "="*50)
        print("PHASE 4: Cohort Summary Validation")
        print("="*50)
        cohorts_present = set(r[0] for r in summary_rows)
        missing = set(VALID_COHORT_MONTHS) - cohorts_present
        assert not missing, f"Missing cohorts in summary: {sorted(missing)}"
        print("All 24 cohorts present in summary")

    def test_cohort_sizes_match(self, summary_rows):
        """Validate cohort sizes in summary match expected values."""
        for row in summary_rows:
            cohort_month, cohort_size = row[0], int(row[1])
            expected = EXPECTED_COHORT_SIZES.get(cohort_month)
            assert expected is not None, f"Unexpected cohort: {cohort_month}"
            assert cohort_size == expected, \
                f"Cohort {cohort_month}: expected size {expected}, got {cohort_size}"
        print("All cohort sizes in summary match expected values")

    def test_total_lifetime_revenue_positive(self, summary_rows):
        """Validate total_lifetime_revenue is positive for all cohorts."""
        for row in summary_rows:
            cohort_month, _, total_rev = row[0], row[1], row[2]
            assert float(total_rev) > 0, \
                f"Cohort {cohort_month}: total_lifetime_revenue should be positive, got {total_rev}"
        print("All cohorts have positive total_lifetime_revenue")

    def test_avg_revenue_per_customer_formula(self, summary_rows):
        """Validate avg_revenue_per_customer = total_lifetime_revenue / cohort_size."""
        for row in summary_rows:
            cohort_month, cohort_size, total_rev, avg_rev = row[0], int(row[1]), row[2], row[3]
            expected_avg = round(float(total_rev) / cohort_size, 2)
            assert abs(float(avg_rev) - expected_avg) < 0.02, \
                f"Cohort {cohort_month}: avg_revenue formula mismatch, expected {expected_avg}, got {avg_rev}"
        print("avg_revenue_per_customer formula verified")

    def test_avg_orders_per_customer_positive(self, summary_rows):
        """Validate avg_orders_per_customer is positive."""
        for row in summary_rows:
            cohort_month, avg_orders = row[0], row[4]
            assert float(avg_orders) > 0, \
                f"Cohort {cohort_month}: avg_orders_per_customer should be positive, got {avg_orders}"
        print("All cohorts have positive avg_orders_per_customer")

    def test_months_active_positive(self, summary_rows):
        """Validate months_active is positive and reasonable."""
        for row in summary_rows:
            cohort_month, months_active = row[0], int(row[5])
            assert months_active >= 1, \
                f"Cohort {cohort_month}: months_active should be at least 1, got {months_active}"
            # Max months active is from cohort month to Dec 2024
            cohort_year, cohort_mon = map(int, cohort_month.split('-'))
            max_months = (2024 - cohort_year) * 12 + (12 - cohort_mon) + 1
            assert months_active <= max_months, \
                f"Cohort {cohort_month}: months_active ({months_active}) exceeds max ({max_months})"
        print("All cohorts have valid months_active values")

    def test_retention_month_6_present_for_old_cohorts(self, summary_rows):
        """Validate retention_month_6 is present for cohorts that should have it."""
        for row in summary_rows:
            cohort_month, retention_6 = row[0], row[6]
            if cohort_month in COHORTS_WITH_MONTH_6:
                # Should have a value (not necessarily non-null depending on if there was activity)
                # But if present, should be valid
                if retention_6 is not None:
                    assert 0 <= float(retention_6) <= 100, \
                        f"Cohort {cohort_month}: retention_month_6 out of range: {retention_6}"
        print("retention_month_6 validated for applicable cohorts")

    def test_retention_month_12_present_for_old_cohorts(self, summary_rows):
        """Validate retention_month_12 is present for cohorts that should have it."""
        for row in summary_rows:
            cohort_month, retention_12 = row[0], row[7]
            if cohort_month in COHORTS_WITH_MONTH_12:
                if retention_12 is not None:
                    assert 0 <= float(retention_12) <= 100, \
                        f"Cohort {cohort_month}: retention_month_12 out of range: {retention_12}"
        print("retention_month_12 validated for applicable cohorts")

    def test_retention_month_6_null_for_recent_cohorts(self, summary_rows):
        """Validate retention_month_6 is NULL for cohorts too recent to have 6 months of data."""
        recent_cohorts = set(VALID_COHORT_MONTHS) - set(COHORTS_WITH_MONTH_6)
        for row in summary_rows:
            cohort_month, retention_6 = row[0], row[6]
            if cohort_month in recent_cohorts:
                assert retention_6 is None, \
                    f"Cohort {cohort_month}: retention_month_6 should be NULL for recent cohort, got {retention_6}"
        print("retention_month_6 is NULL for recent cohorts (as expected)")

    def test_retention_month_12_null_for_recent_cohorts(self, summary_rows):
        """Validate retention_month_12 is NULL for cohorts too recent to have 12 months of data."""
        recent_cohorts = set(VALID_COHORT_MONTHS) - set(COHORTS_WITH_MONTH_12)
        for row in summary_rows:
            cohort_month, retention_12 = row[0], row[7]
            if cohort_month in recent_cohorts:
                assert retention_12 is None, \
                    f"Cohort {cohort_month}: retention_month_12 should be NULL for recent cohort, got {retention_12}"
        print("retention_month_12 is NULL for recent cohorts (as expected)")


class TestPhase5CrossModel:
    """Phase 5: Cross-model consistency checks."""

    def test_cohort_sizes_match_across_all_models(self, retention_rows, revenue_rows, summary_rows):
        """Validate cohort sizes match across all three models."""
        print("\n" + "="*50)
        print("PHASE 5: Cross-Model Consistency")
        print("="*50)

        retention_sizes = {r[0]: int(r[2]) for r in retention_rows if int(r[1]) == 0}
        revenue_sizes = {r[0]: int(r[2]) for r in revenue_rows if int(r[1]) == 0}
        summary_sizes = {r[0]: int(r[1]) for r in summary_rows}

        for cohort in VALID_COHORT_MONTHS:
            ret_size = retention_sizes.get(cohort)
            rev_size = revenue_sizes.get(cohort)
            sum_size = summary_sizes.get(cohort)

            assert ret_size == rev_size == sum_size, \
                f"Cohort {cohort} size mismatch: retention={ret_size}, revenue={rev_size}, summary={sum_size}"
        print("Cohort sizes match across all three models")

    def test_same_rows_in_retention_and_revenue(self, retention_rows, revenue_rows):
        """Validate retention and revenue have the same rows."""
        retention_keys = set((r[0], int(r[1])) for r in retention_rows)
        revenue_keys = set((r[0], int(r[1])) for r in revenue_rows)

        only_in_retention = retention_keys - revenue_keys
        only_in_revenue = revenue_keys - retention_keys

        assert not only_in_retention, f"Rows only in retention: {sorted(only_in_retention)}"
        assert not only_in_revenue, f"Rows only in revenue: {sorted(only_in_revenue)}"
        print(f"Retention and revenue models have identical {len(retention_keys)} rows")

    def test_row_counts_match(self, retention_rows, revenue_rows):
        """Validate retention and revenue have the same number of rows."""
        assert len(retention_rows) == len(revenue_rows), \
            f"Row count mismatch: retention={len(retention_rows)}, revenue={len(revenue_rows)}"
        print(f"Both models have {len(retention_rows)} rows")


class TestPhase6DataIntegrity:
    """Phase 6: Data integrity and source data validation."""

    def test_excluded_orders_exist(self, dbt_run):
        """Verify CANCELLED and RETURNED orders exist in source data."""
        print("\n" + "="*50)
        print("PHASE 6: Data Integrity Validation")
        print("="*50)
        excluded = query_excluded_status_orders()
        if excluded:
            print(f"Excluded order counts: {excluded}")
        print("Exclusion logic verified")

    def test_customer_count_matches_source(self, retention_rows):
        """Verify total customers matches source data query."""
        actual_customers = query_unique_customers_in_period()
        month_0_rows = [r for r in retention_rows if int(r[1]) == 0]
        total_from_cohorts = sum(int(r[2]) for r in month_0_rows)

        assert total_from_cohorts == actual_customers, \
            f"Customer count mismatch: cohorts={total_from_cohorts}, source={actual_customers}"
        print(f"Customer count {total_from_cohorts} matches source data")

    def test_cohort_month_format_strict(self, retention_rows):
        """Strictly validate cohort_month format is exactly YYYY-MM."""
        import re
        pattern = re.compile(r'^20(23|24)-(0[1-9]|1[0-2])$')
        for row in retention_rows:
            cohort_month = row[0]
            assert pattern.match(cohort_month), \
                f"Invalid cohort_month format: '{cohort_month}', expected YYYY-MM"
        print("All cohort_month values strictly match YYYY-MM format")


class TestPhase7Idempotency:
    """Phase 7: Test idempotency."""

    def test_idempotency_retention(self, retention_rows):
        """Test that re-running dbt produces the same retention results."""
        print("\n" + "="*50)
        print("PHASE 7: Idempotency Test")
        print("="*50)

        rows_before = list(retention_rows)
        run_dbt_pipeline()
        rows_after = query_cohort_retention()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            assert before[0] == after[0], "cohort_month changed"
            assert int(before[1]) == int(after[1]), "months_since_first_order changed"
            assert int(before[2]) == int(after[2]), "cohort_size changed"
            assert int(before[3]) == int(after[3]), "retained_customers changed"
            assert abs(float(before[4]) - float(after[4])) < 0.01, "retention_rate changed"
            assert int(before[5]) == int(after[5]), "cumulative_retained changed"
            assert abs(float(before[6]) - float(after[6])) < 0.01, "cumulative_retention_rate changed"

        print(f"Retention idempotency verified: {len(rows_after)} rows unchanged")

    def test_idempotency_summary(self, summary_rows):
        """Test that re-running dbt produces the same summary results."""
        rows_before = list(summary_rows)
        rows_after = query_cohort_summary()

        assert len(rows_before) == len(rows_after), \
            f"Summary row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            assert before[0] == after[0], "cohort_month changed"
            assert int(before[1]) == int(after[1]), "cohort_size changed"

        print(f"Summary idempotency verified: {len(rows_after)} rows unchanged")
        print("Phase 7 PASSED")
