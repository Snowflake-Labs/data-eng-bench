"""
Test verifier for GL Reconciliation and Trial Balance task.
Multi-phase testing:
  Phase 1: Validate model structure and basic functionality
  Phase 2: Validate calculation accuracy
  Phase 3: Validate unusual balance detection
  Phase 4: Validate direction logic for different account types
  Phase 5: Test net_balance calculation
  Phase 6: Validate period_summary model
"""
import subprocess
import os
from decimal import Decimal
from collections import Counter
import pytest

# ============ EXPECTED VALUES ============

# Expected account count (20 accounts in chart of accounts)
EXPECTED_ACCOUNT_COUNT = 20

# Expected number of out-of-balance entries (most are single-line entries)
EXPECTED_OUT_OF_BALANCE_COUNT_MIN = 5000

# Expected unusual balance accounts (account_number, expected_direction, actual_direction)
# These are accounts where the actual balance direction differs from expected
EXPECTED_UNUSUAL_ACCOUNTS = [
    ('1100', 'DEBIT', 'CREDIT'),    # Accounts Receivable - negative when should be positive
    ('1200', 'DEBIT', 'CREDIT'),    # Inventory - negative when should be positive
    ('1300', 'DEBIT', 'CREDIT'),    # Prepaid Expenses - negative when should be positive
    ('1500', 'DEBIT', 'CREDIT'),    # Fixed Assets - negative when should be positive
    ('1600', 'CREDIT', 'DEBIT'),    # Accumulated Depreciation (CONTRA) - positive when should be negative
    ('3000', 'CREDIT', 'DEBIT'),    # Common Stock - positive when should be negative
    ('4000', 'CREDIT', 'DEBIT'),    # Sales Revenue - positive when should be negative
    ('4100', 'CREDIT', 'DEBIT'),    # Service Revenue - positive when should be negative
    ('5000', 'DEBIT', 'CREDIT'),    # COGS - negative when should be positive
    ('6000', 'DEBIT', 'CREDIT'),    # Salaries Expense - negative when should be positive
    ('6200', 'DEBIT', 'CREDIT'),    # Utilities Expense - negative when should be positive
]

# Sample account balances to verify (account_number, expected_net_balance with tolerance)
SAMPLE_ACCOUNT_BALANCES = [
    ('1000', Decimal('292077.4300'), Decimal('0.01')),  # Cash (ASSET: debits - credits)
    ('2000', Decimal('501123.6400'), Decimal('0.01')),  # Accounts Payable (LIABILITY: credits - debits)
    ('6300', Decimal('900733.1400'), Decimal('0.01')),  # Marketing Expense (EXPENSE: debits - credits)
]

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
    """Run dbt run."""
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def validate_table_exists(table_name):
    """Check if a table exists in analytics schema."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE LOWER(table_schema) = 'gl_analytics'
            AND LOWER(table_name) = '{table_name.lower()}'
        """)
        return result > 0
    finally:
        conn.close()


def validate_columns(table_name, required_columns):
    """Check if required columns exist."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE LOWER(table_schema) = 'gl_analytics'
            AND LOWER(table_name) = '{table_name.lower()}'
        """)
        existing = {r[0].lower() for r in result}
        missing = set(c.lower() for c in required_columns) - existing
        assert not missing, f"Missing columns in {table_name}: {missing}"
        print(f"  All required columns present in {table_name}")
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1ModelStructure:
    """Phase 1: Validate model structure and required columns."""

    def test_account_balances_exists(self, dbt_run):
        """Validate account_balances table exists."""
        print("\n" + "="*50)
        print("PHASE 1: Model Structure Validation")
        print("="*50)
        assert validate_table_exists('account_balances'), \
            "Table gl_analytics.account_balances does not exist"
        print("  account_balances table exists")

    def test_account_balances_columns(self, dbt_run):
        """Validate account_balances has required columns."""
        validate_columns('account_balances', [
            'account_id', 'account_number', 'account_name', 'account_type',
            'total_debits', 'total_credits', 'net_balance'
        ])

    def test_trial_balance_exists(self, dbt_run):
        """Validate trial_balance table exists."""
        assert validate_table_exists('trial_balance'), \
            "Table gl_analytics.trial_balance does not exist"
        print("  trial_balance table exists")

    def test_trial_balance_columns(self, dbt_run):
        """Validate trial_balance has required columns."""
        validate_columns('trial_balance', [
            'total_debit_balances', 'total_credit_balances', 'difference', 'is_balanced'
        ])

    def test_out_of_balance_entries_exists(self, dbt_run):
        """Validate out_of_balance_entries table exists."""
        assert validate_table_exists('out_of_balance_entries'), \
            "Table gl_analytics.out_of_balance_entries does not exist"
        print("  out_of_balance_entries table exists")

    def test_out_of_balance_entries_columns(self, dbt_run):
        """Validate out_of_balance_entries has required columns."""
        validate_columns('out_of_balance_entries', [
            'transaction_number', 'entry_date', 'total_debits', 'total_credits',
            'imbalance_amount', 'line_count'
        ])

    def test_unusual_balance_accounts_exists(self, dbt_run):
        """Validate unusual_balance_accounts table exists."""
        assert validate_table_exists('unusual_balance_accounts'), \
            "Table gl_analytics.unusual_balance_accounts does not exist"
        print("  unusual_balance_accounts table exists")

    def test_unusual_balance_accounts_columns(self, dbt_run):
        """Validate unusual_balance_accounts has required columns."""
        validate_columns('unusual_balance_accounts', [
            'account_id', 'account_number', 'account_name', 'account_type',
            'account_subtype', 'net_balance', 'expected_direction', 'actual_direction', 'is_unusual'
        ])


class TestPhase2CalculationAccuracy:
    """Phase 2: Validate calculation accuracy."""

    def test_account_count(self, dbt_run):
        """Validate account count is correct."""
        print("\n" + "="*50)
        print("PHASE 2: Calculation Accuracy Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM gl_analytics.account_balances
            """)
            assert result == EXPECTED_ACCOUNT_COUNT, \
                f"Expected {EXPECTED_ACCOUNT_COUNT} accounts, got {result}"
            print(f"  Account count correct: {result}")
        finally:
            conn.close()

    def test_sample_account_balances(self, dbt_run):
        """Validate sample account balance values."""
        conn, db_type = get_db_connection()
        try:
            for acct_num, expected_balance, tolerance in SAMPLE_ACCOUNT_BALANCES:
                rows = execute_query(conn, db_type, f"""
                    SELECT net_balance FROM gl_analytics.account_balances
                    WHERE account_number = '{acct_num}'
                """)
                assert rows, f"Account {acct_num} not found"
                actual = Decimal(str(rows[0][0]))
                diff = abs(actual - expected_balance)
                assert diff <= tolerance, \
                    f"Account {acct_num} balance mismatch: expected {expected_balance}, got {actual}"
                print(f"  Account {acct_num} balance correct: {actual}")
        finally:
            conn.close()

    def test_trial_balance_single_row(self, dbt_run):
        """Validate trial_balance has exactly one row."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM gl_analytics.trial_balance
            """)
            assert result == 1, f"trial_balance should have exactly 1 row, got {result}"
            print(f"  trial_balance has 1 row")
        finally:
            conn.close()

    def test_out_of_balance_count(self, dbt_run):
        """Validate out_of_balance_entries count is reasonable."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM gl_analytics.out_of_balance_entries
            """)
            assert result >= EXPECTED_OUT_OF_BALANCE_COUNT_MIN, \
                f"Expected at least {EXPECTED_OUT_OF_BALANCE_COUNT_MIN} out-of-balance entries, got {result}"
            print(f"  out_of_balance_entries count: {result}")
        finally:
            conn.close()

    def test_imbalance_threshold(self, dbt_run):
        """Verify all out_of_balance_entries have imbalance > 0.01."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM gl_analytics.out_of_balance_entries
                WHERE imbalance_amount <= 0.01
            """)
            assert result == 0, \
                f"Found {result} entries with imbalance <= 0.01, should be filtered out"
            print(f"  All out_of_balance_entries have imbalance > 0.01")
        finally:
            conn.close()


class TestPhase3UnusualBalanceDetection:
    """Phase 3: Validate unusual balance detection logic."""

    def test_unusual_accounts_match(self, dbt_run):
        """Validate unusual balance accounts are correctly identified."""
        print("\n" + "="*50)
        print("PHASE 3: Unusual Balance Detection Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT account_number, expected_direction, actual_direction
                FROM gl_analytics.unusual_balance_accounts
                ORDER BY account_number
            """)

            actual_unusual = {(r[0], r[1], r[2]) for r in result}
            expected_unusual = {tuple(x) for x in EXPECTED_UNUSUAL_ACCOUNTS}

            missing = expected_unusual - actual_unusual
            extra = actual_unusual - expected_unusual

            if missing:
                print(f"  Missing unusual accounts: {missing}")
            if extra:
                print(f"  Extra unusual accounts: {extra}")

            assert not missing and not extra, \
                f"Unusual balance accounts mismatch. Missing: {len(missing)}, Extra: {len(extra)}"
            print(f"  All {len(EXPECTED_UNUSUAL_ACCOUNTS)} unusual accounts correctly identified")
        finally:
            conn.close()

    def test_is_unusual_flag(self, dbt_run):
        """Verify is_unusual is TRUE for all rows in unusual_balance_accounts."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM gl_analytics.unusual_balance_accounts
                WHERE is_unusual != TRUE
            """)
            assert result == 0, "All rows in unusual_balance_accounts should have is_unusual = TRUE"
            print(f"  All rows have is_unusual = TRUE")
        finally:
            conn.close()


class TestPhase4DirectionLogic:
    """Phase 4: Validate expected direction logic for different account types."""

    def test_contra_account_direction(self, dbt_run):
        """Validate CONTRA accounts are handled correctly."""
        print("\n" + "="*50)
        print("PHASE 4: Direction Logic Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            # Account 1600 (Accumulated Depreciation) is ASSET CONTRA - should expect CREDIT
            rows = execute_query(conn, db_type, """
                SELECT account_number, expected_direction
                FROM gl_analytics.unusual_balance_accounts
                WHERE account_number = '1600'
            """)
            assert rows, "Account 1600 not in unusual_balance_accounts"
            assert rows[0][1] == 'CREDIT', \
                f"Account 1600 (ASSET CONTRA) should have expected_direction = CREDIT, got {rows[0][1]}"
            print(f"  CONTRA account direction logic correct for 1600")

            # Check Returns & Allowances (4200) - REVENUE CONTRA should expect DEBIT
            # This account is not unusual because it has a DEBIT balance as expected
            rows = execute_query(conn, db_type, """
                SELECT net_balance FROM gl_analytics.account_balances
                WHERE account_number = '4200'
            """)
            print(f"  Account 4200 (REVENUE CONTRA) balance: {rows[0][0]}")
        finally:
            conn.close()


class TestPhase5NetBalanceCalculation:
    """Phase 5: Validate net_balance respects account type direction."""

    def test_asset_balance_calculation(self, dbt_run):
        """Validate ASSET account net_balance = debits - credits."""
        print("\n" + "="*50)
        print("PHASE 5: Net Balance Calculation Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            # Check Cash (ASSET) - should be debits - credits
            rows = execute_query(conn, db_type, """
                SELECT total_debits, total_credits, net_balance, account_type
                FROM gl_analytics.account_balances
                WHERE account_number = '1000'
            """)
            assert rows and rows[0][0] is not None, "No data for account 1000"
            expected = float(rows[0][0]) - float(rows[0][1])
            actual = float(rows[0][2])
            assert abs(expected - actual) < 0.01, \
                f"Cash net_balance calculation incorrect. Expected {expected}, got {actual}"
            print(f"  ASSET (Cash) net_balance correct: debits - credits = {actual}")
        finally:
            conn.close()

    def test_liability_balance_calculation(self, dbt_run):
        """Validate LIABILITY account net_balance = credits - debits."""
        conn, db_type = get_db_connection()
        try:
            # Check Accounts Payable (LIABILITY) - should be credits - debits
            rows = execute_query(conn, db_type, """
                SELECT total_debits, total_credits, net_balance, account_type
                FROM gl_analytics.account_balances
                WHERE account_number = '2000'
            """)
            assert rows and rows[0][0] is not None, "No data for account 2000"
            expected = float(rows[0][1]) - float(rows[0][0])
            actual = float(rows[0][2])
            assert abs(expected - actual) < 0.01, \
                f"Accounts Payable net_balance calculation incorrect. Expected {expected}, got {actual}"
            print(f"  LIABILITY (Accounts Payable) net_balance correct: credits - debits = {actual}")
        finally:
            conn.close()

    def test_expense_balance_calculation(self, dbt_run):
        """Validate EXPENSE account net_balance = debits - credits."""
        conn, db_type = get_db_connection()
        try:
            # Check Marketing Expense (EXPENSE) - should be debits - credits
            rows = execute_query(conn, db_type, """
                SELECT total_debits, total_credits, net_balance, account_type
                FROM gl_analytics.account_balances
                WHERE account_number = '6300'
            """)
            assert rows and rows[0][0] is not None, "No data for account 6300"
            expected = float(rows[0][0]) - float(rows[0][1])
            actual = float(rows[0][2])
            assert abs(expected - actual) < 0.01, \
                f"Marketing Expense net_balance calculation incorrect. Expected {expected}, got {actual}"
            print(f"  EXPENSE (Marketing Expense) net_balance correct: debits - credits = {actual}")
        finally:
            conn.close()


class TestPhase6PeriodSummary:
    """Phase 6: Validate period_summary model."""

    def test_period_summary_exists(self, dbt_run):
        """Validate period_summary table exists."""
        print("\n" + "="*50)
        print("PHASE 6: Period Summary Validation")
        print("="*50)
        assert validate_table_exists('period_summary'), \
            "Table gl_analytics.period_summary does not exist"
        print("  period_summary table exists")

    def test_period_summary_columns(self, dbt_run):
        """Validate period_summary has required columns."""
        validate_columns('period_summary', [
            'period_id', 'period_name', 'fiscal_year', 'fiscal_quarter', 'fiscal_month',
            'start_date', 'end_date', 'period_status', 'total_debits', 'total_credits',
            'net_activity', 'transaction_count', 'prior_period_net_activity', 'activity_change'
        ])

    def test_period_count(self, dbt_run):
        """Validate period_summary includes all periods from source."""
        conn, db_type = get_db_connection()
        try:
            # Get expected count from source
            expected = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM FINANCE.GL_PERIODS
            """)

            actual = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM gl_analytics.period_summary
            """)

            assert actual == expected, \
                f"Expected {expected} periods (all from GL_PERIODS), got {actual}"
            print(f"  Period count correct: {actual}")
        finally:
            conn.close()

    def test_period_totals_match_transactions(self, dbt_run):
        """Validate period totals match actual transaction sums."""
        conn, db_type = get_db_connection()
        try:
            # Compare period_summary totals with raw transaction totals
            result = execute_scalar(conn, db_type, """
                WITH expected AS (
                    SELECT
                        p.PERIOD_ID,
                        COALESCE(SUM(gl.DEBIT_AMOUNT), 0) as expected_debits,
                        COALESCE(SUM(gl.CREDIT_AMOUNT), 0) as expected_credits
                    FROM FINANCE.GL_PERIODS p
                    LEFT JOIN FINANCE.GL_TRANSACTIONS gl ON p.PERIOD_ID = gl.PERIOD_ID
                    GROUP BY p.PERIOD_ID
                ),
                actual AS (
                    SELECT period_id, total_debits, total_credits
                    FROM gl_analytics.period_summary
                )
                SELECT COUNT(*) as mismatch_count
                FROM expected e
                JOIN actual a ON e.PERIOD_ID = a.period_id
                WHERE ABS(e.expected_debits - a.total_debits) > 0.01
                   OR ABS(e.expected_credits - a.total_credits) > 0.01
            """)
            assert result == 0, \
                f"Found {result} periods with mismatched totals"
            print(f"  All period totals match transaction sums")
        finally:
            conn.close()

    def test_activity_change_calculation(self, dbt_run):
        """Validate activity_change = net_activity - prior_period_net_activity."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, """
                SELECT COUNT(*) as error_count
                FROM gl_analytics.period_summary
                WHERE ABS(activity_change - (net_activity - prior_period_net_activity)) > 0.01
            """)
            assert result == 0, \
                f"Found {result} periods with incorrect activity_change calculation"
            print(f"  activity_change calculation correct for all periods")
        finally:
            conn.close()

    def test_fiscal_year_range(self, dbt_run):
        """Validate fiscal years match source data range."""
        conn, db_type = get_db_connection()
        try:
            # Get expected range from source
            expected = execute_query(conn, db_type, """
                SELECT MIN(FISCAL_YEAR), MAX(FISCAL_YEAR)
                FROM FINANCE.GL_PERIODS
            """)

            actual = execute_query(conn, db_type, """
                SELECT MIN(fiscal_year), MAX(fiscal_year)
                FROM gl_analytics.period_summary
            """)

            assert actual[0][0] == expected[0][0] and actual[0][1] == expected[0][1], \
                f"Expected fiscal years {expected[0][0]}-{expected[0][1]}, got {actual[0][0]}-{actual[0][1]}"
            print(f"  Fiscal year range correct: {actual[0][0]}-{actual[0][1]}")
        finally:
            conn.close()

    def test_period_ordering(self, dbt_run):
        """Validate periods are ordered by fiscal_year, fiscal_month (no out-of-order pairs)."""
        conn, db_type = get_db_connection()
        try:
            # Check that no row has a prior row with a later date (comparing adjacent rows)
            result = execute_scalar(conn, db_type, """
                WITH numbered AS (
                    SELECT
                        fiscal_year,
                        fiscal_month,
                        LAG(fiscal_year) OVER (ORDER BY fiscal_year, fiscal_month) as prev_year,
                        LAG(fiscal_month) OVER (ORDER BY fiscal_year, fiscal_month) as prev_month
                    FROM gl_analytics.period_summary
                )
                SELECT COUNT(*) as out_of_order_count
                FROM numbered
                WHERE prev_year IS NOT NULL
                  AND (fiscal_year < prev_year
                       OR (fiscal_year = prev_year AND fiscal_month < prev_month))
            """)
            assert result == 0, "Periods are not ordered by fiscal_year, fiscal_month"
            print(f"  Periods correctly ordered by fiscal_year, fiscal_month")
        finally:
            conn.close()
