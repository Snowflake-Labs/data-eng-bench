"""
Test verifier for Customer Account Balance Ledger task.
Multi-phase testing for comprehensive validation.
"""
import os
import subprocess
from collections import Counter
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
            schema='finance_analytics',
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


def get_dbt_project_dir():
    """Get the dbt project directory."""
    return "/app/dbt_project"


# ============ CONFIGURATION ============

SCHEMA = "finance_analytics"
PROJECT_DIR = get_dbt_project_dir()

# ============ EXPECTED VALUES ============

REQUIRED_BALANCE_COLUMNS = [
    "transaction_id", "customer_id", "transaction_type", "transaction_date",
    "transaction_amount", "previous_balance", "running_balance", "transaction_sequence",
    "balance_status", "days_since_last_payment", "is_high_balance",
    "balance_change_direction", "cumulative_orders", "cumulative_payments",
    "is_first_transaction", "balance_trend", "consecutive_orders", "consecutive_payments",
    "days_since_first_transaction"
]

REQUIRED_SUMMARY_COLUMNS = [
    "customer_id", "total_orders", "total_payments", "total_order_amount",
    "total_payment_amount", "final_balance", "final_status",
    "avg_days_between_payments", "max_balance_reached", "account_health_score",
    "longest_order_streak", "account_age_days"
]

REQUIRED_RISK_COLUMNS = [
    "customer_id", "final_balance", "payment_frequency", "balance_volatility",
    "streak_risk", "overall_risk_score", "risk_category"
]

VALID_TRANSACTION_TYPES = ['ORDER', 'PAYMENT']
VALID_BALANCE_STATUS = ['CREDIT', 'ZERO', 'DEBIT']
VALID_CHANGE_DIRECTIONS = ['INCREASE', 'DECREASE', 'NO_CHANGE']
VALID_BALANCE_TRENDS = ['IMPROVING', 'WORSENING', 'STABLE']
VALID_FREQ_CATEGORIES = ['HIGH', 'MEDIUM', 'LOW']
VALID_RISK_CATEGORIES = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']

EXPECTED_VALID_ORDERS = 1891
EXPECTED_POSTED_PAYMENTS = 1800
EXPECTED_TOTAL_TRANSACTIONS = EXPECTED_VALID_ORDERS + EXPECTED_POSTED_PAYMENTS

# ============ HELPERS ============


def run_cmd(cmd, cwd=PROJECT_DIR):
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt run pipeline."""
    deps = run_cmd("dbt deps --profiles-dir /app/dbt_project")
    if deps.returncode != 0:
        print("dbt deps failed (may be harmless if no packages).")
    result = run_cmd("dbt run --select +rpt_risk_assessment --full-refresh --profiles-dir /app/dbt_project")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_running_balance():
    """Query customer_running_balance model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                transaction_id, customer_id, transaction_type, transaction_date,
                transaction_amount, previous_balance, running_balance, transaction_sequence,
                balance_status, days_since_last_payment, is_high_balance,
                balance_change_direction, cumulative_orders, cumulative_payments,
                is_first_transaction, balance_trend, consecutive_orders, consecutive_payments,
                days_since_first_transaction
            FROM {SCHEMA}.customer_running_balance
            ORDER BY customer_id, transaction_date, transaction_id
        """)
        return rows
    finally:
        conn.close()


def query_account_summary():
    """Query rpt_customer_account_summary model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id, total_orders, total_payments, total_order_amount,
                total_payment_amount, final_balance, final_status,
                avg_days_between_payments, max_balance_reached, account_health_score,
                longest_order_streak, account_age_days
            FROM {SCHEMA}.rpt_customer_account_summary
            ORDER BY customer_id
        """)
        return rows
    finally:
        conn.close()


def query_risk_assessment():
    """Query rpt_risk_assessment model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id, final_balance, payment_frequency, balance_volatility,
                streak_risk, overall_risk_score, risk_category
            FROM {SCHEMA}.rpt_risk_assessment
            ORDER BY customer_id
        """)
        return rows
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def balance_rows(dbt_run):
    return query_running_balance()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    return query_account_summary()


@pytest.fixture(scope="module")
def risk_rows(dbt_run):
    return query_risk_assessment()


# ============ VALIDATION HELPERS ============

def validate_balance_columns():
    """Validate that customer_running_balance has all required columns."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'customer_running_balance'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {c.lower() for c in REQUIRED_BALANCE_COLUMNS}
        missing = required - col_names
        assert not missing, f"Missing columns in customer_running_balance: {missing}"
    finally:
        conn.close()


def validate_summary_columns():
    """Validate that rpt_customer_account_summary has all required columns."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'rpt_customer_account_summary'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {c.lower() for c in REQUIRED_SUMMARY_COLUMNS}
        missing = required - col_names
        assert not missing, f"Missing columns in rpt_customer_account_summary: {missing}"
    finally:
        conn.close()


def validate_risk_columns():
    """Validate that rpt_risk_assessment has all required columns."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'rpt_risk_assessment'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {c.lower() for c in REQUIRED_RISK_COLUMNS}
        missing = required - col_names
        assert not missing, f"Missing columns in rpt_risk_assessment: {missing}"
    finally:
        conn.close()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    def test_balance_columns_exist(self, dbt_run):
        """Verify customer_running_balance has all required columns."""
        validate_balance_columns()

    def test_summary_columns_exist(self, dbt_run):
        """Verify rpt_customer_account_summary has all required columns."""
        validate_summary_columns()

    def test_risk_columns_exist(self, dbt_run):
        """Verify rpt_risk_assessment has all required columns."""
        validate_risk_columns()

    def test_transaction_count(self, balance_rows):
        """Verify total transaction count matches expected orders + payments."""
        actual = len(balance_rows)
        assert actual == EXPECTED_TOTAL_TRANSACTIONS


class TestPhase2TransactionAmounts:
    def test_order_amounts_positive(self, balance_rows):
        """Verify all ORDER transactions have positive amounts."""
        orders = [row for row in balance_rows if row[2] == 'ORDER']
        for row in orders:
            amount = float(row[4])
            assert amount > 0

    def test_payment_amounts_negative(self, balance_rows):
        """Verify all PAYMENT transactions have negative amounts."""
        payments = [row for row in balance_rows if row[2] == 'PAYMENT']
        for row in payments:
            amount = float(row[4])
            assert amount < 0


class TestPhase3RunningBalance:
    def test_running_balance_calculation(self, balance_rows):
        """Verify running_balance is a correct cumulative sum of transaction amounts per customer."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = []
            customers[cust_id].append(row)

        for cust_id, transactions in customers.items():
            transactions.sort(key=lambda x: (x[3], x[0]))
            cumulative = 0
            for row in transactions:
                amount = float(row[4])
                expected_balance = cumulative + amount
                actual_balance = float(row[6])
                cumulative = expected_balance
                assert abs(actual_balance - expected_balance) < 0.01

    def test_first_transaction_previous_balance_zero(self, balance_rows):
        """Verify previous_balance is zero for each customer's first transaction."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = []
            customers[cust_id].append(row)

        for cust_id, transactions in customers.items():
            transactions.sort(key=lambda x: (x[3], x[0]))
            first = transactions[0]
            prev_bal = float(first[5])
            assert abs(prev_bal) < 0.01


class TestPhase4BalanceStatus:
    def test_balance_status_correct(self, balance_rows):
        """Verify balance_status is CREDIT when negative, ZERO when zero, DEBIT when positive."""
        for row in balance_rows:
            running_bal = float(row[6])
            status = row[8]
            if running_bal < 0:
                assert status == 'CREDIT'
            elif abs(running_bal) < 0.01:
                assert status == 'ZERO'
            else:
                assert status == 'DEBIT'


class TestPhase5ConsecutiveStreaks:
    def test_consecutive_orders_logic(self, balance_rows):
        """Verify consecutive_orders increments for ORDER streaks and resets to 0 on PAYMENT."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = []
            customers[cust_id].append(row)

        for cust_id, transactions in customers.items():
            transactions.sort(key=lambda x: (x[3], x[0]))
            order_streak = 0
            for row in transactions:
                if row[2] == 'ORDER':
                    order_streak += 1
                    assert int(row[16]) == order_streak
                else:
                    order_streak = 0
                    assert int(row[16]) == 0

    def test_consecutive_payments_logic(self, balance_rows):
        """Verify consecutive_payments increments for PAYMENT streaks and resets to 0 on ORDER."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = []
            customers[cust_id].append(row)

        for cust_id, transactions in customers.items():
            transactions.sort(key=lambda x: (x[3], x[0]))
            payment_streak = 0
            for row in transactions:
                if row[2] == 'PAYMENT':
                    payment_streak += 1
                    assert int(row[17]) == payment_streak
                else:
                    payment_streak = 0
                    assert int(row[17]) == 0


class TestPhase6DaysSinceFirst:
    def test_days_since_first_transaction(self, balance_rows):
        """Verify days_since_first_transaction matches actual day difference from first transaction.
        Allows +/-1 tolerance for DATEDIFF vs Python timedelta differences on TIMESTAMP columns."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = []
            customers[cust_id].append(row)

        for cust_id, transactions in customers.items():
            transactions.sort(key=lambda x: (x[3], x[0]))
            first_date = transactions[0][3]
            for row in transactions:
                expected_days = (row[3] - first_date).days
                actual_days = int(row[18])
                assert abs(actual_days - expected_days) <= 1, \
                    f"Customer {cust_id}: days_since_first_transaction {actual_days} != expected {expected_days}"


class TestPhase7AccountSummary:
    def test_summary_customer_count(self, summary_rows, balance_rows):
        """Verify summary has one row per unique customer from balance data."""
        unique_customers = len(set(row[1] for row in balance_rows))
        assert len(summary_rows) == unique_customers

    def test_longest_order_streak(self, summary_rows, balance_rows):
        """Verify longest_order_streak matches the max consecutive_orders from balance data."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = 0
            customers[cust_id] = max(customers[cust_id], int(row[16]))

        for row in summary_rows:
            cust_id = row[0]
            expected = customers.get(cust_id, 0)
            actual = int(row[10])
            assert actual == expected

    def test_account_age_days(self, summary_rows, balance_rows):
        """Verify account_age_days equals days between first and last transaction.
        Allows +/-1 tolerance for DATEDIFF vs Python timedelta differences on TIMESTAMP columns."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = {'first': row[3], 'last': row[3]}
            customers[cust_id]['last'] = row[3]

        for row in summary_rows:
            cust_id = row[0]
            if cust_id in customers:
                expected = (customers[cust_id]['last'] - customers[cust_id]['first']).days
                actual = int(row[11])
                assert abs(actual - expected) <= 1, \
                    f"Customer {cust_id}: account_age_days {actual} != expected {expected}"


class TestPhase8RiskAssessment:
    def test_risk_customer_count(self, risk_rows, summary_rows):
        """Verify risk assessment has the same number of customers as account summary."""
        assert len(risk_rows) == len(summary_rows)

    def test_payment_frequency_valid(self, risk_rows):
        """Verify payment_frequency is HIGH, MEDIUM, or LOW for all customers."""
        for row in risk_rows:
            assert row[2] in VALID_FREQ_CATEGORIES

    def test_balance_volatility_valid(self, risk_rows):
        """Verify balance_volatility is HIGH, MEDIUM, or LOW for all customers."""
        for row in risk_rows:
            assert row[3] in VALID_FREQ_CATEGORIES

    def test_streak_risk_valid(self, risk_rows):
        """Verify streak_risk is HIGH, MEDIUM, or LOW for all customers."""
        for row in risk_rows:
            assert row[4] in VALID_FREQ_CATEGORIES

    def test_overall_risk_score_range(self, risk_rows):
        """Verify overall_risk_score is within the 3-10 range for all customers."""
        for row in risk_rows:
            score = int(row[5])
            assert 3 <= score <= 10

    def test_risk_category_valid(self, risk_rows):
        """Verify risk_category is CRITICAL, HIGH, MEDIUM, or LOW for all customers."""
        for row in risk_rows:
            assert row[6] in VALID_RISK_CATEGORIES

    def test_risk_category_logic(self, risk_rows):
        """Verify risk_category matches score thresholds: >=9 CRITICAL, >=7 HIGH, >=5 MEDIUM, else LOW."""
        for row in risk_rows:
            score = int(row[5])
            category = row[6]
            if score >= 9:
                assert category == 'CRITICAL'
            elif score >= 7:
                assert category == 'HIGH'
            elif score >= 5:
                assert category == 'MEDIUM'
            else:
                assert category == 'LOW'


class TestPhase9DataIntegrity:
    def test_unique_transactions(self, balance_rows):
        """Verify all transaction_id values are unique with no duplicates."""
        trans_ids = [row[0] for row in balance_rows]
        duplicates = [tid for tid, count in Counter(trans_ids).items() if count > 1]
        assert not duplicates

    def test_transaction_sequence(self, balance_rows):
        """Verify transaction_sequence is sequential (1, 2, 3, ...) per customer."""
        customers = {}
        for row in balance_rows:
            cust_id = row[1]
            if cust_id not in customers:
                customers[cust_id] = []
            customers[cust_id].append(row)

        for cust_id, transactions in customers.items():
            transactions.sort(key=lambda x: (x[3], x[0]))
            for i, row in enumerate(transactions, 1):
                seq = int(row[7])
                assert seq == i

    def test_deterministic_ordering(self, balance_rows):
        """Verify re-running the pipeline produces identical results (idempotency)."""
        rows_before = list(balance_rows)
        run_dbt_pipeline()
        rows_after = query_running_balance()
        assert len(rows_before) == len(rows_after)
        for before, after in zip(rows_before, rows_after):
            assert before == after

    def test_order_count_matches_source(self, balance_rows):
        """Verify the number of ORDER transactions matches expected valid orders from source."""
        order_count = len([row for row in balance_rows if row[2] == 'ORDER'])
        assert order_count == EXPECTED_VALID_ORDERS

    def test_payment_count_matches_source(self, balance_rows):
        """Verify the number of PAYMENT transactions matches expected posted payments from source."""
        payment_count = len([row for row in balance_rows if row[2] == 'PAYMENT'])
        assert payment_count == EXPECTED_POSTED_PAYMENTS
