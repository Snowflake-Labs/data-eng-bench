"""
Test verifier for Deferred Revenue Recognition Schedule task.
Multi-phase testing:
  Phase 1: Validate model structure and required columns
  Phase 2: Validate recognition logic and calculations
  Phase 3: Validate cumulative and remaining calculations
  Phase 4: Test idempotency
"""
import subprocess
import os
import re
import pytest


# Schema where the model is created (existing project prefixes with main_)
MODEL_SCHEMA = "main_finance_analytics"
MODEL_NAME = "deferred_revenue_schedule"


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
            schema=MODEL_SCHEMA,
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

def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


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
    """Run dbt deps and dbt run for the deferred_revenue_schedule model."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    result = run_cmd("dbt run --select deferred_revenue_schedule")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_model():
    """Query deferred_revenue_schedule model with all columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                deferred_id,
                order_id,
                order_type,
                total_deferred_amount,
                period_name,
                period_start_date,
                period_end_date,
                recognition_start,
                recognition_end,
                days_in_period,
                total_recognition_days,
                calculated_recognition_amount,
                posted_recognition_amount,
                recognition_variance,
                recognition_method,
                cumulative_recognized,
                deferred_remaining
            FROM {MODEL_SCHEMA}.{MODEL_NAME}
            ORDER BY deferred_id, period_start_date
        """)
        return rows
    finally:
        conn.close()


def get_sample_deferred_entry():
    """Get a sample deferred entry for validation."""
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            total_days_expr = "DATEDIFF('day', d.RECOGNITION_START, d.RECOGNITION_END) + 1"
        else:
            total_days_expr = "(d.RECOGNITION_END - d.RECOGNITION_START) + 1"
        result = execute_query(conn, db_type, f"""
            SELECT
                d.DEFERRED_ID,
                d.ORDER_ID,
                o.ORDER_TYPE,
                d.AMOUNT as total_deferred_amount,
                d.RECOGNITION_START,
                d.RECOGNITION_END,
                {total_days_expr} as total_days
            FROM FINANCE.DEFERRED_REVENUE d
            JOIN ORDERS.ORDERS o ON d.ORDER_ID = o.ORDER_ID
            WHERE d.RECOGNITION_START IS NOT NULL
            ORDER BY d.DEFERRED_ID
            LIMIT 1
        """)
        return result[0] if result else None
    finally:
        conn.close()


def get_entry_count():
    """Get count of valid deferred entries."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT DEFERRED_ID)
            FROM FINANCE.DEFERRED_REVENUE
            WHERE RECOGNITION_START IS NOT NULL AND RECOGNITION_END IS NOT NULL
        """)
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
def model_rows(dbt_run):
    """Fixture that provides model rows after dbt run."""
    return query_model()


@pytest.fixture(scope="module")
def sample_entry():
    """Fixture that provides a sample deferred entry."""
    return get_sample_deferred_entry()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and required columns."""

    def test_model_file_exists(self, dbt_run):
        """Validate the model file exists at the expected location."""
        model_path = f"{get_dbt_project_dir()}/models/marts/finance/deferred_revenue_schedule.sql"
        assert os.path.exists(model_path), \
            f"Model file not found at {model_path}. Create the model in models/marts/finance/"

    def test_model_exists_in_schema(self, dbt_run):
        """Validate the model exists in the correct schema."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = '{MODEL_SCHEMA.lower()}'
                AND lower(table_name) = '{MODEL_NAME.lower()}'
            """)
            assert result >= 1, f"Model {MODEL_NAME} not found in schema {MODEL_SCHEMA}"
        finally:
            conn.close()

    def test_all_required_columns_exist(self, dbt_run):
        """Validate all 17 required columns exist."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = '{MODEL_SCHEMA.lower()}'
                AND lower(table_name) = '{MODEL_NAME.lower()}'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                "deferred_id", "order_id", "order_type", "total_deferred_amount",
                "period_name", "period_start_date", "period_end_date",
                "recognition_start", "recognition_end",
                "days_in_period", "total_recognition_days",
                "calculated_recognition_amount", "posted_recognition_amount",
                "recognition_variance", "recognition_method",
                "cumulative_recognized", "deferred_remaining"
            }
            missing = required - col_names
            assert not missing, f"Missing columns in {MODEL_NAME}: {missing}"
        finally:
            conn.close()

    def test_has_rows(self, model_rows):
        """Validate model has data."""
        assert len(model_rows) > 0, f"{MODEL_NAME} has no rows"

    def test_period_name_format(self, model_rows):
        """Validate period_name is in YYYY-MM format."""
        pattern = re.compile(r'^\d{4}-\d{2}$')
        for row in model_rows:
            period = row[4]  # period_name is index 4
            assert pattern.match(str(period)), f"Period name '{period}' not in YYYY-MM format"


class TestPhase2RecognitionLogic:
    """Phase 2: Validate recognition logic and calculations."""

    def test_recognition_method_values(self, model_rows):
        """Validate recognition_method is either STRAIGHT_LINE or IMMEDIATE."""
        valid_methods = {'STRAIGHT_LINE', 'IMMEDIATE'}
        for row in model_rows:
            method = row[14]  # recognition_method is index 14
            assert method in valid_methods, \
                f"Invalid recognition method '{method}'. Expected STRAIGHT_LINE or IMMEDIATE."

    def test_straight_line_threshold(self, model_rows):
        """Validate entries with 60+ days use STRAIGHT_LINE method."""
        for row in model_rows:
            total_days = row[10]  # total_recognition_days is index 10
            method = row[14]  # recognition_method is index 14
            if total_days >= 60:
                assert method == 'STRAIGHT_LINE', \
                    f"Entry with {total_days} days should use STRAIGHT_LINE, not {method}"

    def test_immediate_threshold(self, model_rows):
        """Validate entries with <60 days use IMMEDIATE method."""
        for row in model_rows:
            total_days = row[10]  # total_recognition_days is index 10
            method = row[14]  # recognition_method is index 14
            if total_days < 60:
                assert method == 'IMMEDIATE', \
                    f"Entry with {total_days} days should use IMMEDIATE, not {method}"

    def test_immediate_full_amount_in_first_period(self, model_rows):
        """Validate IMMEDIATE method has full amount in first period only."""
        # Group by deferred_id
        entries = {}
        for row in model_rows:
            deferred_id = row[0]
            method = row[14]  # recognition_method
            period_start = str(row[5])  # period_start_date
            calc_amount = float(row[11])  # calculated_recognition_amount
            total = float(row[3])  # total_deferred_amount

            if method == 'IMMEDIATE':
                if deferred_id not in entries:
                    entries[deferred_id] = {'periods': [], 'total': total}
                entries[deferred_id]['periods'].append((period_start, calc_amount))

        # Check each IMMEDIATE entry
        for deferred_id, data in entries.items():
            sorted_periods = sorted(data['periods'], key=lambda x: x[0])
            if len(sorted_periods) > 0:
                # First period should have full amount
                first_amount = sorted_periods[0][1]
                assert abs(first_amount - data['total']) < 0.01, \
                    f"IMMEDIATE entry {deferred_id}: first period amount ({first_amount}) != total ({data['total']})"
                # Subsequent periods should have 0
                for period_start, amount in sorted_periods[1:]:
                    assert abs(amount) < 0.01, \
                        f"IMMEDIATE entry {deferred_id}: period {period_start} should have 0, got {amount}"

    def test_recognition_sum_matches_total(self, model_rows):
        """Validate sum of calculated_recognition_amount equals total_deferred_amount for each entry."""
        entries = {}
        for row in model_rows:
            deferred_id = row[0]
            calc_amount = float(row[11])  # calculated_recognition_amount is index 11
            total = float(row[3])  # total_deferred_amount is index 3

            if deferred_id not in entries:
                entries[deferred_id] = {'sum': 0.0, 'total': total}
            entries[deferred_id]['sum'] += calc_amount

        # Check each entry (allow small rounding tolerance)
        for deferred_id, data in entries.items():
            diff = abs(data['sum'] - data['total'])
            assert diff < 0.1, \
                f"Deferred ID {deferred_id}: sum of recognition ({data['sum']:.2f}) != total ({data['total']:.2f})"

    def test_days_in_period_sum_matches_total_days(self, model_rows):
        """Validate sum of days_in_period equals total_recognition_days for each entry."""
        entries = {}
        for row in model_rows:
            deferred_id = row[0]
            days_in_period = int(row[9])  # days_in_period is index 9
            total_days = int(row[10])  # total_recognition_days is index 10

            if deferred_id not in entries:
                entries[deferred_id] = {'sum_days': 0, 'total_days': total_days}
            entries[deferred_id]['sum_days'] += days_in_period

        # Check each entry
        for deferred_id, data in entries.items():
            assert data['sum_days'] == data['total_days'], \
                f"Deferred ID {deferred_id}: sum of days ({data['sum_days']}) != total ({data['total_days']})"

    def test_variance_calculation(self, model_rows):
        """Validate recognition_variance = calculated - posted."""
        for row in model_rows:
            calculated = float(row[11])  # calculated_recognition_amount
            posted = float(row[12])  # posted_recognition_amount
            variance = float(row[13])  # recognition_variance

            expected_variance = round(calculated - posted, 2)
            assert abs(variance - expected_variance) < 0.01, \
                f"Variance {variance} != calculated ({calculated}) - posted ({posted}) = {expected_variance}"


class TestPhase3CumulativeCalculations:
    """Phase 3: Validate cumulative and remaining calculations."""

    def test_cumulative_recognized_increases(self, model_rows):
        """Validate cumulative_recognized increases monotonically within each deferred_id."""
        current_id = None
        prev_cumulative = None

        for row in model_rows:
            deferred_id = row[0]
            cumulative = float(row[15])  # cumulative_recognized is index 15

            if deferred_id != current_id:
                current_id = deferred_id
                prev_cumulative = cumulative
            else:
                assert cumulative >= prev_cumulative - 0.01, \
                    f"Deferred ID {deferred_id}: cumulative_recognized decreased from {prev_cumulative} to {cumulative}"
                prev_cumulative = cumulative

    def test_deferred_remaining_decreases(self, model_rows):
        """Validate deferred_remaining decreases monotonically within each deferred_id."""
        current_id = None
        prev_remaining = None

        for row in model_rows:
            deferred_id = row[0]
            remaining = float(row[16])  # deferred_remaining is index 16

            if deferred_id != current_id:
                current_id = deferred_id
                prev_remaining = remaining
            else:
                assert remaining <= prev_remaining + 0.01, \
                    f"Deferred ID {deferred_id}: deferred_remaining increased from {prev_remaining} to {remaining}"
                prev_remaining = remaining

    def test_final_period_deferred_remaining_near_zero(self, model_rows):
        """Validate the last period for each entry has deferred_remaining near zero."""
        entries = {}
        for row in model_rows:
            deferred_id = row[0]
            remaining = float(row[16])  # deferred_remaining is index 16
            entries[deferred_id] = remaining  # Last one wins

        for deferred_id, remaining in entries.items():
            assert abs(remaining) < 0.1, \
                f"Deferred ID {deferred_id}: final deferred_remaining ({remaining}) should be near 0"


class TestPhase4DataValidation:
    """Phase 4: Validate data against source."""

    def test_period_dates_are_valid(self, model_rows):
        """Validate period_start_date is first of month and period_end_date is last of month."""
        for row in model_rows:
            start_date = row[5]  # period_start_date is index 5
            end_date = row[6]  # period_end_date is index 6

            # Extract day from start_date (handles both date objects and strings)
            if hasattr(start_date, 'day'):
                start_day = start_date.day
            else:
                # Handle string format "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS"
                start_str = str(start_date).split(' ')[0]  # Remove time component if present
                start_day = int(start_str.split('-')[-1])

            assert start_day == 1, f"Period start date {start_date} should be first of month"

            # Extract day from end_date (handles both date objects and strings)
            if hasattr(end_date, 'day'):
                end_day = end_date.day
            else:
                # Handle string format "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS"
                end_str = str(end_date).split(' ')[0]  # Remove time component if present
                end_day = int(end_str.split('-')[-1])

            assert 28 <= end_day <= 31, f"Period end date {end_date} should be last of month"

    def test_data_matches_database(self, model_rows, sample_entry):
        """Validate a sample entry matches the database."""
        if sample_entry is None:
            pytest.skip("No deferred revenue data found")

        expected_id, expected_order, expected_type, expected_amount, _, _, expected_days = sample_entry

        # Find in model rows
        found = False
        for row in model_rows:
            if row[0] == expected_id:
                found = True
                assert row[1] == expected_order, f"Order ID mismatch: {row[1]} != {expected_order}"
                assert row[2] == expected_type, f"Order type mismatch: {row[2]} != {expected_type}"
                assert abs(float(row[3]) - float(expected_amount)) < 0.01, \
                    f"Amount mismatch: {row[3]} != {expected_amount}"
                assert int(row[10]) == expected_days, f"Total days mismatch: {row[10]} != {expected_days}"
                break

        assert found, f"Deferred ID {expected_id} not found in results"

    def test_all_entries_included(self, model_rows):
        """Validate all valid deferred entries are included."""
        expected_count = get_entry_count()
        actual_ids = set(row[0] for row in model_rows)
        actual_count = len(actual_ids)
        assert actual_count == expected_count, \
            f"Entry count mismatch: model has {actual_count}, expected {expected_count}"


class TestPhase5Ordering:
    """Phase 5: Validate result ordering."""

    def test_sorted_correctly(self, model_rows):
        """Validate results are sorted by deferred_id, then period_start_date."""
        for i in range(1, len(model_rows)):
            prev = model_rows[i-1]
            curr = model_rows[i]
            if prev[0] > curr[0]:
                pytest.fail(f"Not sorted by deferred_id: {prev[0]} > {curr[0]}")
            elif prev[0] == curr[0]:
                if str(prev[5]) > str(curr[5]):
                    pytest.fail(f"Not sorted by period_start_date: {prev[5]} > {curr[5]}")


class TestPhase6Idempotency:
    """Phase 6: Test idempotency."""

    def test_idempotency(self, model_rows):
        """Test that re-running dbt produces the same results."""
        rows_before = sorted(list(model_rows), key=lambda x: (x[0], str(x[5])))

        run_dbt_pipeline()

        rows_after = sorted(query_model(), key=lambda x: (x[0], str(x[5])))

        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            assert before == after, \
                f"Row changed after re-run:\nBefore: {before}\nAfter: {after}"
