"""
Test verifier for Weekly Sales Growth task.
Multi-phase testing with strict validation:
  Phase 1: Validate model structure
  Phase 2: Validate column order and data types
  Phase 3: Validate calculations and NULL handling
  Phase 4: Spot-check specific weeks (hidden ground truth)
  Phase 5: Test idempotency
"""
import subprocess
import os
from datetime import date
import pytest

# ============ EXPECTED VALUES (HIDDEN GROUND TRUTH) ============

EXPECTED_WEEK_COUNT = 26
EXPECTED_TOTAL_REVENUE = 44134.80

# Required columns in exact order (13 columns)
REQUIRED_COLUMNS_ORDERED = [
    "week_start", "week_number", "order_count", "unique_customers",
    "total_revenue", "avg_order_value", "prev_week_revenue",
    "revenue_change", "revenue_growth_pct", "growth_status",
    "rolling_4wk_avg_revenue", "cumulative_revenue", "is_best_week"
]

# Spot check weeks with all key values (Sunday-based weeks):
# (week_start, week_number, order_count, unique_customers, total_revenue,
#  growth_status, cumulative_revenue, is_best_week)
SPOT_CHECK_WEEKS = [
    ('2023-12-31', 1, 1, 1, 1506.39, None, 1506.39, 'Y'),      # First week starts on Sunday Dec 31
    ('2024-01-07', 2, 5, 5, 1440.36, 'Declining', 2946.75, 'N'),  # -4.38% -> Declining
    ('2024-01-14', 3, 2, 2, 986.87, 'Declining', 3933.62, 'N'),   # -31.48% -> Declining
    ('2024-01-21', 4, 1, 1, 342.65, 'Sharp Decline', 4276.27, 'N'), # -65.28% -> Sharp Decline
    ('2024-01-28', 5, 4, 4, 992.88, 'Strong Growth', 5269.15, 'N'), # +189.77% -> Strong Growth
    ('2024-02-04', 6, 6, 5, 1402.0, 'Growing', 6671.15, 'N'),     # +41.21% -> Growing
]

# Best week spot checks - weeks where is_best_week should be 'Y'
BEST_WEEK_CHECKS = [
    ('2023-12-31', 1, 1506.39, 'Y'),  # First week is always best so far
    ('2024-02-18', 8, 1791.23, 'Y'),  # New high at 1791.23
    ('2024-03-03', 10, 2796.68, 'Y'), # New high at 2796.68
    ('2024-03-24', 13, 2873.84, 'Y'), # New high at 2873.84
    ('2024-05-05', 19, 3196.10, 'Y'), # New high at 3196.10
    ('2024-05-12', 20, 3235.98, 'Y'), # New high at 3235.98
]

LAST_WEEK = ('2024-06-23', 26, 7, 7, 3152.93, 'Strong Growth', 44134.80, 'N')
WEEK_4_ROLLING_AVG = 1069.07

# Growth status validation with thresholds:
# Strong Growth: >= 50%, Growing: 0-50%, Stable: 0%, Declining: -50% to 0%, Sharp Decline: <= -50%
GROWTH_STATUS_WEEKS = [
    ('2024-01-07', 'Declining'),      # Week 2: -4.38%
    ('2024-01-21', 'Sharp Decline'),  # Week 4: -65.28%
    ('2024-01-28', 'Strong Growth'),  # Week 5: +189.77%
    ('2024-02-04', 'Growing'),        # Week 6: +41.21%
    ('2024-02-11', 'Sharp Decline'),  # Week 7: -51.97%
    ('2024-03-03', 'Strong Growth'),  # Week 10: +274.01%
    ('2024-06-23', 'Strong Growth'),  # Week 26: +51.98%
]

# First week must start on Sunday Dec 31, 2023
FIRST_WEEK_START = '2023-12-31'

# Schema is `sales_analytics` for both backends (matches what instruction.md
# tells the agent: "Schema: sales_analytics", set in profiles.yml). Previous
# version returned 'main' for Snowflake, which silently disagreed with the
# spec — agents wrote correct data into `sales_analytics` and the verifier
# couldn't find it. See build #3010 root cause: agent's data matched ground
# truth exactly, only delta was schema name.
def _get_schema():
    return 'sales_analytics'

SCHEMA = _get_schema()

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
                schema=SCHEMA,
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
    return result


def run_dbt_pipeline():
    """Run dbt run."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        result = run_cmd("dbt run --select stg_orders__weekly int_weekly_sales weekly_sales_growth")
    else:
        result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_weekly_sales():
    """Query weekly_sales_growth model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                week_start,
                week_number,
                order_count,
                unique_customers,
                total_revenue,
                avg_order_value,
                prev_week_revenue,
                revenue_change,
                revenue_growth_pct,
                growth_status,
                rolling_4wk_avg_revenue,
                cumulative_revenue,
                is_best_week
            FROM {SCHEMA}.weekly_sales_growth
            ORDER BY week_start
        """)
        return rows
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def weekly_rows(dbt_run):
    """Fixture that provides weekly_sales_growth rows after dbt run."""
    return query_weekly_sales()


# ============ PHASE 1: STRUCTURE VALIDATION ============

class TestPhase1Structure:
    """Phase 1: Validate model structure."""

    def test_model_exists(self, dbt_run):
        """Validate weekly_sales_growth model exists."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = lower('{SCHEMA}')
                AND lower(table_name) = 'weekly_sales_growth'
            """)
            assert result[0][0] > 0, "Model weekly_sales_growth not found"
        finally:
            conn.close()

    def test_is_table_not_view(self, dbt_run):
        """Validate model is materialized as TABLE."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT table_type FROM information_schema.tables
                WHERE lower(table_schema) = lower('{SCHEMA}')
                AND lower(table_name) = 'weekly_sales_growth'
            """)
            assert len(result) > 0, "Model not found"
            table_type = result[0][0].upper()
            assert 'VIEW' not in table_type, f"Must be TABLE, got {table_type}"
        finally:
            conn.close()

    def test_all_required_models_exist(self, dbt_run):
        """Validate all required models exist."""
        conn, db_type = get_db_connection()
        try:
            for model in ['stg_orders__weekly', 'int_weekly_sales', 'weekly_sales_growth']:
                result = execute_query(conn, db_type, f"""
                    SELECT COUNT(*) FROM information_schema.tables
                    WHERE lower(table_schema) = lower('{SCHEMA}')
                    AND lower(table_name) = '{model}'
                """)
                assert result[0][0] > 0, f"Model {model} not found"
        finally:
            conn.close()


# ============ PHASE 2: COLUMN VALIDATION ============

class TestPhase2Columns:
    """Phase 2: Validate column order and data types."""

    def test_column_order(self, dbt_run):
        """Validate columns appear in exact order."""
        print("\n" + "="*50)
        print("PHASE 2: Column Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{SCHEMA}')
                AND lower(table_name) = 'weekly_sales_growth'
                ORDER BY ordinal_position
            """)
            actual_cols = [c[0].lower() for c in cols]
            expected_cols = [c.lower() for c in REQUIRED_COLUMNS_ORDERED]

            assert actual_cols == expected_cols, \
                f"Column order mismatch.\nExpected: {expected_cols}\nActual: {actual_cols}"
        finally:
            conn.close()

    def test_week_start_is_date(self, dbt_run):
        """Validate week_start is DATE type."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT data_type
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{SCHEMA}')
                AND lower(table_name) = 'weekly_sales_growth'
                AND lower(column_name) = 'week_start'
            """)
            assert len(result) > 0, "Column week_start not found"
            data_type = result[0][0].upper()
            assert 'DATE' in data_type and 'TIME' not in data_type, \
                f"week_start must be DATE, got {data_type}"
        finally:
            conn.close()

    def test_column_count(self, dbt_run):
        """Validate exactly 13 columns exist."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*)
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{SCHEMA}')
                AND lower(table_name) = 'weekly_sales_growth'
            """)
            assert result[0][0] == 13, f"Expected 13 columns, got {result[0][0]}"
        finally:
            conn.close()


# ============ PHASE 3: DATA VALIDATION ============

class TestPhase3Data:
    """Phase 3: Validate calculations and NULL handling."""

    def test_exact_week_count(self, weekly_rows):
        """Validate exact number of weeks."""
        print("\n" + "="*50)
        print("PHASE 3: Data Validation")
        print("="*50)
        actual = len(weekly_rows)
        assert actual == EXPECTED_WEEK_COUNT, \
            f"Expected {EXPECTED_WEEK_COUNT} weeks, got {actual}"

    def test_total_revenue(self, weekly_rows):
        """Validate total revenue across all weeks."""
        total = sum(float(row[4]) for row in weekly_rows)
        assert abs(total - EXPECTED_TOTAL_REVENUE) < 0.1, \
            f"Total revenue mismatch: expected {EXPECTED_TOTAL_REVENUE}, got {round(total, 2)}"

    def test_first_week_starts_on_sunday(self, weekly_rows):
        """Validate first week starts on Sunday Dec 31, 2023."""
        first_row = weekly_rows[0]
        first_week = str(first_row[0])
        assert first_week == FIRST_WEEK_START, \
            f"First week should start on {FIRST_WEEK_START} (Sunday), got {first_week}"

    def test_all_weeks_start_on_sunday(self, weekly_rows):
        """Validate all week_start dates are Sundays."""
        for row in weekly_rows:
            week_date = row[0]
            if hasattr(week_date, 'weekday'):
                assert week_date.weekday() == 6, \
                    f"Week {row[1]} starts on {week_date} which is not a Sunday (weekday={week_date.weekday()})"
            else:
                # Snowflake may return date as string
                from datetime import datetime
                d = datetime.strptime(str(week_date), '%Y-%m-%d').date()
                assert d.weekday() == 6, \
                    f"Week {row[1]} starts on {week_date} which is not a Sunday (weekday={d.weekday()})"

    def test_first_week_nulls(self, weekly_rows):
        """Validate first week has NULL for prev_week_revenue, revenue_change, revenue_growth_pct, growth_status."""
        first_row = weekly_rows[0]
        assert first_row[6] is None, f"First week prev_week_revenue should be NULL, got {first_row[6]}"
        assert first_row[7] is None, f"First week revenue_change should be NULL, got {first_row[7]}"
        assert first_row[8] is None, f"First week revenue_growth_pct should be NULL, got {first_row[8]}"
        assert first_row[9] is None, f"First week growth_status should be NULL, got {first_row[9]}"

    def test_first_three_weeks_no_rolling_avg(self, weekly_rows):
        """Validate first 3 weeks have NULL rolling_4wk_avg_revenue."""
        for i in range(min(3, len(weekly_rows))):
            row = weekly_rows[i]
            assert row[10] is None, \
                f"Week {i+1} rolling_4wk_avg_revenue should be NULL, got {row[10]}"

    def test_week_4_has_rolling_avg(self, weekly_rows):
        """Validate week 4 has non-NULL rolling average."""
        if len(weekly_rows) >= 4:
            row = weekly_rows[3]
            assert row[10] is not None, "Week 4 should have rolling_4wk_avg_revenue"
            expected_avg = WEEK_4_ROLLING_AVG
            actual_avg = float(row[10])
            assert abs(actual_avg - expected_avg) < 0.1, \
                f"Week 4 rolling avg: expected {expected_avg}, got {actual_avg}"

    def test_revenue_change_calculation(self, weekly_rows):
        """Validate revenue_change = total_revenue - prev_week_revenue."""
        for i, row in enumerate(weekly_rows[1:], start=1):
            if row[6] is not None and row[7] is not None:
                expected_change = round(float(row[4]) - float(row[6]), 2)
                actual_change = float(row[7])
                assert abs(actual_change - expected_change) < 0.1, \
                    f"Week {i+1}: revenue_change mismatch"

    def test_revenue_growth_pct_calculation(self, weekly_rows):
        """Validate revenue_growth_pct = (change / prev) * 100."""
        for i, row in enumerate(weekly_rows[1:], start=1):
            if row[6] is not None and row[7] is not None and float(row[6]) > 0:
                if row[8] is not None:
                    expected_pct = round((float(row[7]) / float(row[6])) * 100, 2)
                    actual_pct = float(row[8])
                    assert abs(actual_pct - expected_pct) < 0.5, \
                        f"Week {i+1}: growth pct mismatch - expected {expected_pct}, got {actual_pct}"

    def test_growth_status_values(self, weekly_rows):
        """Validate growth_status is one of the valid values."""
        valid_statuses = {'Strong Growth', 'Growing', 'Stable', 'Declining', 'Sharp Decline', None}
        for row in weekly_rows:
            status = row[9]
            assert status in valid_statuses, \
                f"Invalid growth_status: '{status}'. Must be 'Strong Growth', 'Growing', 'Stable', 'Declining', 'Sharp Decline', or NULL"

    def test_growth_status_logic(self, weekly_rows):
        """Validate growth_status matches revenue_growth_pct thresholds."""
        for i, row in enumerate(weekly_rows):
            growth_pct = row[8]
            status = row[9]
            if growth_pct is None:
                assert status is None, f"Week {i+1}: growth_status should be NULL when growth_pct is NULL"
            else:
                pct = float(growth_pct)
                if pct >= 50:
                    expected = 'Strong Growth'
                elif pct > 0:
                    expected = 'Growing'
                elif pct == 0:
                    expected = 'Stable'
                elif pct > -50:
                    expected = 'Declining'
                else:
                    expected = 'Sharp Decline'
                assert status == expected, f"Week {i+1}: growth_status should be '{expected}' for {pct}%, got '{status}'"

    def test_cumulative_revenue_calculation(self, weekly_rows):
        """Validate cumulative_revenue is running total."""
        running_total = 0
        for i, row in enumerate(weekly_rows):
            running_total += float(row[4])
            actual_cumulative = float(row[11])
            assert abs(actual_cumulative - running_total) < 0.1, \
                f"Week {i+1}: cumulative_revenue mismatch - expected {round(running_total, 2)}, got {actual_cumulative}"

    def test_is_best_week_values(self, weekly_rows):
        """Validate is_best_week is exactly 'Y' or 'N'."""
        for row in weekly_rows:
            is_best = row[12]
            assert is_best in ('Y', 'N'), \
                f"is_best_week must be 'Y' or 'N', got '{is_best}'"

    def test_is_best_week_logic(self, weekly_rows):
        """Validate is_best_week logic - Y when revenue equals max so far."""
        max_so_far = 0
        for i, row in enumerate(weekly_rows):
            total_revenue = float(row[4])
            if total_revenue > max_so_far:
                max_so_far = total_revenue

            expected_best = 'Y' if abs(total_revenue - max_so_far) < 0.01 else 'N'
            actual_best = row[12]
            assert actual_best == expected_best, \
                f"Week {i+1}: is_best_week mismatch - expected '{expected_best}', got '{actual_best}' (revenue={total_revenue}, max_so_far={max_so_far})"

    def test_weeks_ordered_ascending(self, weekly_rows):
        """Validate weeks are in ascending order."""
        for i in range(1, len(weekly_rows)):
            assert str(weekly_rows[i][0]) > str(weekly_rows[i-1][0]), \
                f"Weeks not in ascending order at position {i}"

    def test_positive_order_counts(self, weekly_rows):
        """Validate order_count is positive."""
        for row in weekly_rows:
            assert row[2] > 0, f"order_count must be positive, got {row[2]}"

    def test_avg_order_value_calculation(self, weekly_rows):
        """Validate avg_order_value = total_revenue / order_count."""
        for row in weekly_rows:
            expected_avg = round(float(row[4]) / row[2], 2)
            actual_avg = float(row[5])
            assert abs(actual_avg - expected_avg) < 0.1, \
                f"avg_order_value mismatch for week {row[0]}"

    def test_week_numbers_sequential(self, weekly_rows):
        """Validate week_number is sequential starting from 1."""
        for i, row in enumerate(weekly_rows):
            expected_week_num = i + 1
            actual_week_num = row[1]
            assert actual_week_num == expected_week_num, \
                f"Week number should be {expected_week_num}, got {actual_week_num}"


# ============ PHASE 4: SPOT CHECKS ============

class TestPhase4SpotChecks:
    """Phase 4: Spot-check specific weeks (hidden ground truth)."""

    def test_spot_check_weeks(self, weekly_rows):
        """Spot-check specific weeks with known values."""
        print("\n" + "="*50)
        print("PHASE 4: Spot Check Validation")
        print("="*50)

        rows_by_week = {str(row[0]): row for row in weekly_rows}

        for week_start, exp_week_num, exp_orders, exp_customers, exp_revenue, exp_status, exp_cumulative, exp_best in SPOT_CHECK_WEEKS:
            row = rows_by_week.get(week_start)
            assert row is not None, f"Week {week_start} not found"

            assert row[1] == exp_week_num, \
                f"Week {week_start}: week_number={row[1]}, expected={exp_week_num}"
            assert row[2] == exp_orders, \
                f"Week {week_start}: order_count={row[2]}, expected={exp_orders}"
            assert row[3] == exp_customers, \
                f"Week {week_start}: unique_customers={row[3]}, expected={exp_customers}"
            assert abs(float(row[4]) - exp_revenue) < 0.1, \
                f"Week {week_start}: total_revenue={row[4]}, expected={exp_revenue}"
            assert row[9] == exp_status, \
                f"Week {week_start}: growth_status='{row[9]}', expected='{exp_status}'"
            assert abs(float(row[11]) - exp_cumulative) < 0.1, \
                f"Week {week_start}: cumulative_revenue={row[11]}, expected={exp_cumulative}"
            assert row[12] == exp_best, \
                f"Week {week_start}: is_best_week='{row[12]}', expected='{exp_best}'"

    def test_best_week_spot_checks(self, weekly_rows):
        """Validate specific weeks that should be marked as best."""
        rows_by_week = {str(row[0]): row for row in weekly_rows}

        for week_start, week_num, exp_revenue, exp_best in BEST_WEEK_CHECKS:
            row = rows_by_week.get(week_start)
            assert row is not None, f"Week {week_start} not found"

            assert abs(float(row[4]) - exp_revenue) < 0.1, \
                f"Week {week_start}: total_revenue={row[4]}, expected={exp_revenue}"
            assert row[12] == exp_best, \
                f"Week {week_start} (week {week_num}): is_best_week='{row[12]}', expected='{exp_best}' (revenue={exp_revenue})"

    def test_growth_status_spot_checks(self, weekly_rows):
        """Validate growth_status for specific weeks."""
        rows_by_week = {str(row[0]): row for row in weekly_rows}

        for week_start, exp_status in GROWTH_STATUS_WEEKS:
            row = rows_by_week.get(week_start)
            assert row is not None, f"Week {week_start} not found"

            assert row[9] == exp_status, \
                f"Week {week_start}: growth_status='{row[9]}', expected='{exp_status}'"

    def test_last_week(self, weekly_rows):
        """Validate last week data."""
        last_row = weekly_rows[-1]
        week_start, exp_week_num, exp_orders, exp_customers, exp_revenue, exp_status, exp_cumulative, exp_best = LAST_WEEK

        assert str(last_row[0]) == week_start, \
            f"Last week should be {week_start}, got {last_row[0]}"
        assert last_row[1] == exp_week_num, \
            f"Last week_number: expected {exp_week_num}, got {last_row[1]}"
        assert last_row[2] == exp_orders, \
            f"Last week order_count: expected {exp_orders}, got {last_row[2]}"
        assert abs(float(last_row[4]) - exp_revenue) < 0.1, \
            f"Last week revenue: expected {exp_revenue}, got {last_row[4]}"
        assert last_row[9] == exp_status, \
            f"Last week growth_status: expected '{exp_status}', got '{last_row[9]}'"
        assert abs(float(last_row[11]) - exp_cumulative) < 0.1, \
            f"Last week cumulative_revenue: expected {exp_cumulative}, got {last_row[11]}"
        assert last_row[12] == exp_best, \
            f"Last week is_best_week: expected '{exp_best}', got '{last_row[12]}'"


# ============ PHASE 5: IDEMPOTENCY ============

class TestPhase5Idempotency:
    """Phase 5: Test idempotency."""

    def test_idempotency(self, weekly_rows):
        """Test that re-running dbt produces same results."""
        print("\n" + "="*50)
        print("PHASE 5: Idempotency Test")
        print("="*50)

        rows_before = list(weekly_rows)
        run_dbt_pipeline()
        rows_after = query_weekly_sales()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare each field
            for i in range(len(before)):
                if before[i] is None and after[i] is None:
                    continue
                if before[i] is None or after[i] is None:
                    assert False, f"NULL mismatch at index {i}"
                if isinstance(before[i], (int, float)):
                    assert abs(float(before[i]) - float(after[i])) < 0.01, \
                        f"Value changed at index {i}: {before[i]} -> {after[i]}"
                else:
                    assert str(before[i]) == str(after[i]), \
                        f"Value changed at index {i}: {before[i]} -> {after[i]}"

        print(f"Idempotency verified: {len(rows_after)} rows unchanged")
