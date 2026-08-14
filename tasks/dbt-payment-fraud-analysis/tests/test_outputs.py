"""
Test verifier for Payment Method Analysis and Fraud Detection task.
Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate payment_method_summary aggregations
  Phase 3: Validate fraud_risk_summary aggregations
  Phase 4: Validate customer_payment_velocity calculations
  Phase 5: Validate payment_anomalies detection logic
  Phase 6: Test idempotency (re-run produces same results)
"""
import subprocess
import os
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
        conn = duckdb.connect(db_path, read_only=False)
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


# ============ EXPECTED VALUES - computed dynamically ============

def get_expected_payment_methods():
    """Compute expected payment method aggregations from source data."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                PAYMENT_METHOD,
                COUNT(*) as total_transactions,
                SUM(CASE WHEN STATUS = 'FAILED' THEN 1 ELSE 0 END) as failed_count,
                SUM(CASE WHEN STATUS IN ('CAPTURED', 'COMPLETED') THEN 1 ELSE 0 END) as success_count
            FROM ORDERS.ORDER_PAYMENTS
            GROUP BY PAYMENT_METHOD
        """)
        return {row[0]: {'total_transactions': row[1], 'failed_count': row[2], 'success_count': row[3]}
                for row in rows}
    finally:
        conn.close()


def get_expected_fraud_risk():
    """Compute expected fraud risk aggregations from source data."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                f.RISK_LEVEL as risk_level,
                COUNT(DISTINCT f.ORDER_ID) as order_count,
                SUM(CASE WHEN p.STATUS = 'FAILED' THEN 1 ELSE 0 END) as failed_payment_count
            FROM ORDERS.ORDER_FRAUD_SCORES f
            LEFT JOIN ORDERS.ORDER_PAYMENTS p ON f.ORDER_ID = p.ORDER_ID
            WHERE f.RISK_LEVEL IS NOT NULL
            GROUP BY f.RISK_LEVEL
        """)
        return {row[0]: {'order_count': row[1], 'failed_payment_count': row[2]}
                for row in rows}
    finally:
        conn.close()


def get_expected_velocity_counts():
    """Compute expected customer velocity counts from source data."""
    conn, db_type = get_db_connection()
    try:
        # Total customers with payments
        total_customers = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT o.CUSTOMER_ID)
            FROM ORDERS.ORDER_PAYMENTS p
            JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
            WHERE o.CUSTOMER_ID IS NOT NULL
        """)

        # High velocity: payments_per_day > 0.5 OR amount_per_day > 500
        # Use database-specific syntax
        if db_type == 'snowflake':
            high_velocity = execute_scalar(conn, db_type, """
                WITH customer_stats AS (
                    SELECT
                        o.CUSTOMER_ID,
                        COUNT(*) as total_payments,
                        SUM(p.AMOUNT) as total_amount,
                        MIN(p.PROCESSED_AT) as first_payment,
                        MAX(p.PROCESSED_AT) as last_payment,
                        GREATEST(DATEDIFF('day', CAST(MIN(p.PROCESSED_AT) AS DATE), CAST(MAX(p.PROCESSED_AT) AS DATE)), 1) as days_active
                    FROM ORDERS.ORDER_PAYMENTS p
                    JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
                    WHERE o.CUSTOMER_ID IS NOT NULL
                    GROUP BY o.CUSTOMER_ID
                )
                SELECT COUNT(*) FROM customer_stats
                WHERE (CAST(total_payments AS DOUBLE) / days_active) > 0.5
                   OR (CAST(total_amount AS DOUBLE) / days_active) > 500
            """)
        else:
            high_velocity = execute_scalar(conn, db_type, """
                WITH customer_stats AS (
                    SELECT
                        o.CUSTOMER_ID,
                        COUNT(*) as total_payments,
                        SUM(p.AMOUNT) as total_amount,
                        MIN(p.PROCESSED_AT) as first_payment,
                        MAX(p.PROCESSED_AT) as last_payment,
                        GREATEST(DATE_DIFF('day', CAST(MIN(p.PROCESSED_AT) AS DATE), CAST(MAX(p.PROCESSED_AT) AS DATE)), 1) as days_active
                    FROM ORDERS.ORDER_PAYMENTS p
                    JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
                    WHERE o.CUSTOMER_ID IS NOT NULL
                    GROUP BY o.CUSTOMER_ID
                )
                SELECT COUNT(*) FROM customer_stats
                WHERE (CAST(total_payments AS DOUBLE) / days_active) > 0.5
                   OR (CAST(total_amount AS DOUBLE) / days_active) > 500
            """)

        return total_customers, high_velocity
    finally:
        conn.close()


def get_expected_anomaly_count():
    """Get expected number of anomalies (payments with at least one flag)."""
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            count = execute_scalar(conn, db_type, """
                WITH high_velocity_customers AS (
                    SELECT o.CUSTOMER_ID
                    FROM ORDERS.ORDER_PAYMENTS p
                    JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
                    WHERE o.CUSTOMER_ID IS NOT NULL
                    GROUP BY o.CUSTOMER_ID
                    HAVING (CAST(COUNT(*) AS DOUBLE) / GREATEST(DATEDIFF('day', CAST(MIN(p.PROCESSED_AT) AS DATE), CAST(MAX(p.PROCESSED_AT) AS DATE)), 1)) > 0.5
                        OR (CAST(SUM(p.AMOUNT) AS DOUBLE) / GREATEST(DATEDIFF('day', CAST(MIN(p.PROCESSED_AT) AS DATE), CAST(MAX(p.PROCESSED_AT) AS DATE)), 1)) > 500
                ),
                payment_context AS (
                    SELECT
                        p.PAYMENT_ID,
                        p.AMOUNT,
                        p.STATUS,
                        o.CUSTOMER_ID,
                        COALESCE(f.SCORE, 0) as fraud_score,
                        f.RISK_LEVEL,
                        CASE WHEN hv.CUSTOMER_ID IS NOT NULL THEN 1 ELSE 0 END as is_high_velocity
                    FROM ORDERS.ORDER_PAYMENTS p
                    JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
                    LEFT JOIN ORDERS.ORDER_FRAUD_SCORES f ON p.ORDER_ID = f.ORDER_ID
                    LEFT JOIN high_velocity_customers hv ON o.CUSTOMER_ID = hv.CUSTOMER_ID
                )
                SELECT COUNT(*) FROM payment_context
                WHERE AMOUNT > 1000
                   OR fraud_score > 70
                   OR RISK_LEVEL IN ('CRITICAL', 'HIGH')
                   OR STATUS = 'FAILED'
                   OR is_high_velocity = 1
            """)
        else:
            count = execute_scalar(conn, db_type, """
                WITH high_velocity_customers AS (
                    SELECT o.CUSTOMER_ID
                    FROM ORDERS.ORDER_PAYMENTS p
                    JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
                    WHERE o.CUSTOMER_ID IS NOT NULL
                    GROUP BY o.CUSTOMER_ID
                    HAVING (CAST(COUNT(*) AS DOUBLE) / GREATEST(DATE_DIFF('day', CAST(MIN(p.PROCESSED_AT) AS DATE), CAST(MAX(p.PROCESSED_AT) AS DATE)), 1)) > 0.5
                        OR (CAST(SUM(p.AMOUNT) AS DOUBLE) / GREATEST(DATE_DIFF('day', CAST(MIN(p.PROCESSED_AT) AS DATE), CAST(MAX(p.PROCESSED_AT) AS DATE)), 1)) > 500
                ),
                payment_context AS (
                    SELECT
                        p.PAYMENT_ID,
                        p.AMOUNT,
                        p.STATUS,
                        o.CUSTOMER_ID,
                        COALESCE(f.SCORE, 0) as fraud_score,
                        f.RISK_LEVEL,
                        CASE WHEN hv.CUSTOMER_ID IS NOT NULL THEN 1 ELSE 0 END as is_high_velocity
                    FROM ORDERS.ORDER_PAYMENTS p
                    JOIN ORDERS.ORDERS o ON p.ORDER_ID = o.ORDER_ID
                    LEFT JOIN ORDERS.ORDER_FRAUD_SCORES f ON p.ORDER_ID = f.ORDER_ID
                    LEFT JOIN high_velocity_customers hv ON o.CUSTOMER_ID = hv.CUSTOMER_ID
                )
                SELECT COUNT(*) FROM payment_context
                WHERE AMOUNT > 1000
                   OR fraud_score > 70
                   OR RISK_LEVEL IN ('CRITICAL', 'HIGH')
                   OR STATUS = 'FAILED'
                   OR is_high_velocity = 1
            """)
        return count
    finally:
        conn.close()


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
    """Run dbt build to create models."""
    result = run_cmd("dbt build")
    assert result.returncode == 0, f"dbt build failed: {result.stderr}"


def table_exists(conn, db_type, table_name, schema="fraud_analytics"):
    """Check if a table exists in the database."""
    result = execute_scalar(conn, db_type, f"""
        SELECT count(*)
        FROM information_schema.tables
        WHERE lower(table_schema) = lower('{schema}')
        AND lower(table_name) = lower('{table_name}')
    """)
    return result > 0


def get_columns(conn, db_type, table_name, schema="fraud_analytics"):
    """Get column names for a table."""
    result = execute_query(conn, db_type, f"""
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_schema) = lower('{schema}')
        AND lower(table_name) = lower('{table_name}')
    """)
    return {c[0].lower() for c in result}


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def db_connection(dbt_run):
    """Fixture that provides database connection after dbt run."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_payment_method_summary_exists(self, db_connection):
        """Validate payment_method_summary model exists with correct columns."""
        print("\n" + "="*50)
        print("PHASE 1: Structure and Basic Validation")
        print("="*50)

        conn, db_type = db_connection
        assert table_exists(conn, db_type, "payment_method_summary"), \
            "Model payment_method_summary does not exist"

        cols = get_columns(conn, db_type, "payment_method_summary")
        required_cols = {"payment_method", "total_transactions", "total_amount",
                         "avg_transaction_amount", "success_count", "failed_count",
                         "pending_count", "failure_rate"}
        missing = required_cols - cols
        assert not missing, f"payment_method_summary missing columns: {missing}"
        print("payment_method_summary: OK")

    def test_customer_payment_velocity_exists(self, db_connection):
        """Validate customer_payment_velocity model exists with correct columns."""
        conn, db_type = db_connection
        assert table_exists(conn, db_type, "customer_payment_velocity"), \
            "Model customer_payment_velocity does not exist"

        cols = get_columns(conn, db_type, "customer_payment_velocity")
        required_cols = {"customer_id", "total_payments", "total_amount",
                         "distinct_payment_methods", "first_payment_date", "last_payment_date",
                         "days_active", "payments_per_day", "amount_per_day",
                         "max_single_payment", "is_high_velocity"}
        missing = required_cols - cols
        assert not missing, f"customer_payment_velocity missing columns: {missing}"
        print("customer_payment_velocity: OK")

    def test_payment_anomalies_exists(self, db_connection):
        """Validate payment_anomalies model exists with correct columns."""
        conn, db_type = db_connection
        assert table_exists(conn, db_type, "payment_anomalies"), \
            "Model payment_anomalies does not exist"

        cols = get_columns(conn, db_type, "payment_anomalies")
        required_cols = {"payment_id", "order_id", "customer_id", "payment_method",
                         "amount", "processed_at", "fraud_score", "risk_level",
                         "anomaly_flags", "anomaly_count"}
        missing = required_cols - cols
        assert not missing, f"payment_anomalies missing columns: {missing}"
        print("payment_anomalies: OK")

    def test_fraud_risk_summary_exists(self, db_connection):
        """Validate fraud_risk_summary model exists with correct columns."""
        conn, db_type = db_connection
        assert table_exists(conn, db_type, "fraud_risk_summary"), \
            "Model fraud_risk_summary does not exist"

        cols = get_columns(conn, db_type, "fraud_risk_summary")
        required_cols = {"risk_level", "order_count", "total_payment_amount",
                         "avg_fraud_score", "failed_payment_count", "pct_of_total_orders"}
        missing = required_cols - cols
        assert not missing, f"fraud_risk_summary missing columns: {missing}"
        print("fraud_risk_summary: OK")


class TestPhase2PaymentMethodSummary:
    """Phase 2: Validate payment_method_summary aggregations."""

    def test_payment_method_counts(self, db_connection):
        """Validate payment method transaction counts."""
        print("\n" + "="*50)
        print("PHASE 2: Payment Method Summary Validation")
        print("="*50)

        conn, db_type = db_connection
        rows = execute_query(conn, db_type, """
            SELECT payment_method, total_transactions, success_count, failed_count
            FROM fraud_analytics.payment_method_summary
            ORDER BY payment_method
        """)

        actual = {row[0]: {'total_transactions': row[1], 'success_count': row[2], 'failed_count': row[3]}
                  for row in rows}

        expected_payment_methods = get_expected_payment_methods()
        for method, expected in expected_payment_methods.items():
            assert method in actual, f"Missing payment method: {method}"

            assert actual[method]['total_transactions'] == expected['total_transactions'], \
                f"{method}: total_transactions mismatch. Expected {expected['total_transactions']}, got {actual[method]['total_transactions']}"

            assert actual[method]['success_count'] == expected['success_count'], \
                f"{method}: success_count mismatch. Expected {expected['success_count']}, got {actual[method]['success_count']}"

            assert actual[method]['failed_count'] == expected['failed_count'], \
                f"{method}: failed_count mismatch. Expected {expected['failed_count']}, got {actual[method]['failed_count']}"

            print(f"  {method}: OK")

    def test_failure_rate_calculation(self, db_connection):
        """Validate failure_rate calculation."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, """
            SELECT payment_method, failure_rate,
                   CAST(failed_count AS DOUBLE) / total_transactions as expected_rate
            FROM fraud_analytics.payment_method_summary
            WHERE failed_count > 0
        """)

        for row in rows:
            method, actual_rate, expected_rate = row
            assert abs(float(actual_rate) - float(expected_rate)) < 0.001, \
                f"{method}: failure_rate mismatch. Expected ~{expected_rate:.4f}, got {actual_rate}"
        print("Failure rate calculations: OK")


class TestPhase3FraudRiskSummary:
    """Phase 3: Validate fraud_risk_summary aggregations."""

    def test_risk_level_counts(self, db_connection):
        """Validate fraud risk level counts."""
        print("\n" + "="*50)
        print("PHASE 3: Fraud Risk Summary Validation")
        print("="*50)

        conn, db_type = db_connection
        rows = execute_query(conn, db_type, """
            SELECT risk_level, order_count, failed_payment_count
            FROM fraud_analytics.fraud_risk_summary
            ORDER BY risk_level
        """)

        actual = {row[0]: {'order_count': row[1], 'failed_payment_count': row[2]}
                  for row in rows}

        expected_fraud_risk = get_expected_fraud_risk()
        for level, expected in expected_fraud_risk.items():
            assert level in actual, f"Missing risk level: {level}"

            assert actual[level]['order_count'] == expected['order_count'], \
                f"{level}: order_count mismatch. Expected {expected['order_count']}, got {actual[level]['order_count']}"

            assert actual[level]['failed_payment_count'] == expected['failed_payment_count'], \
                f"{level}: failed_payment_count mismatch. Expected {expected['failed_payment_count']}, got {actual[level]['failed_payment_count']}"

            print(f"  {level}: OK")

    def test_pct_of_total_orders_sums_to_one(self, db_connection):
        """Validate pct_of_total_orders sums to approximately 1.0."""
        conn, db_type = db_connection
        total_pct = execute_scalar(conn, db_type, """
            SELECT sum(pct_of_total_orders) FROM fraud_analytics.fraud_risk_summary
        """)

        assert abs(float(total_pct) - 1.0) < 0.01, \
            f"pct_of_total_orders should sum to 1.0, got {total_pct}"
        print("pct_of_total_orders sums to 1.0: OK")


class TestPhase4CustomerVelocity:
    """Phase 4: Validate customer_payment_velocity calculations."""

    def test_customer_count(self, db_connection):
        """Validate total customer count."""
        print("\n" + "="*50)
        print("PHASE 4: Customer Payment Velocity Validation")
        print("="*50)

        conn, db_type = db_connection
        total_customers = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.customer_payment_velocity
        """)

        expected_total, _ = get_expected_velocity_counts()
        assert total_customers == expected_total, \
            f"Customer count mismatch. Expected {expected_total}, got {total_customers}"
        print(f"  Total customers: {total_customers}")

    def test_high_velocity_count(self, db_connection):
        """Validate high velocity customer count."""
        conn, db_type = db_connection
        high_velocity_count = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.customer_payment_velocity
            WHERE CAST(is_high_velocity AS INTEGER) = 1
        """)

        _, expected_high_velocity = get_expected_velocity_counts()
        assert high_velocity_count == expected_high_velocity, \
            f"High velocity count mismatch. Expected {expected_high_velocity}, got {high_velocity_count}"
        print(f"  High velocity customers: {high_velocity_count}")

    def test_velocity_flag_logic(self, db_connection):
        """Validate is_high_velocity flag logic."""
        conn, db_type = db_connection
        # Check that high velocity is correctly flagged
        incorrect_not_flagged = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.customer_payment_velocity
            WHERE (payments_per_day > 0.5 OR amount_per_day > 500) AND COALESCE(CAST(is_high_velocity AS INTEGER), 0) = 0
        """)

        assert incorrect_not_flagged == 0, \
            f"Found {incorrect_not_flagged} customers with high velocity not flagged"

        # Check that low velocity is not flagged
        incorrect_flagged = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.customer_payment_velocity
            WHERE payments_per_day <= 0.5 AND amount_per_day <= 500 AND CAST(is_high_velocity AS INTEGER) = 1
        """)

        assert incorrect_flagged == 0, \
            f"Found {incorrect_flagged} customers incorrectly flagged as high velocity"
        print("  Velocity flag logic: OK")

    def test_days_active_minimum(self, db_connection):
        """Validate days_active minimum is 1."""
        conn, db_type = db_connection
        min_days = execute_scalar(conn, db_type, """
            SELECT min(days_active) FROM fraud_analytics.customer_payment_velocity
        """)

        assert min_days >= 1, f"days_active should be at least 1, found {min_days}"
        print("  days_active minimum >= 1: OK")


class TestPhase5PaymentAnomalies:
    """Phase 5: Validate payment_anomalies detection logic."""

    def test_anomaly_count(self, db_connection):
        """Validate total anomaly count matches expected."""
        print("\n" + "="*50)
        print("PHASE 5: Payment Anomalies Validation")
        print("="*50)

        conn, db_type = db_connection
        anomaly_count = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.payment_anomalies
        """)

        expected_count = get_expected_anomaly_count()
        assert anomaly_count == expected_count, \
            f"Anomaly count mismatch. Expected {expected_count}, got {anomaly_count}"
        print(f"  Total anomalies: {anomaly_count}")

    def test_anomaly_count_matches_flags(self, db_connection):
        """Validate anomaly_count matches number of anomaly_flags."""
        conn, db_type = db_connection
        # Handle both single flags and multiple comma-separated flags
        incorrect = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.payment_anomalies
            WHERE anomaly_count != (
                CASE
                    WHEN anomaly_flags IS NULL OR anomaly_flags = '' THEN 0
                    WHEN anomaly_flags NOT LIKE '%,%' THEN 1
                    ELSE length(anomaly_flags) - length(replace(anomaly_flags, ',', '')) + 1
                END
            )
        """)

        assert incorrect == 0, \
            f"Found {incorrect} rows where anomaly_count doesn't match anomaly_flags"
        print("  anomaly_count matches anomaly_flags: OK")

    def test_all_anomalies_have_flags(self, db_connection):
        """Validate all anomalies have at least one flag."""
        conn, db_type = db_connection
        zero_flags = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.payment_anomalies
            WHERE anomaly_count < 1 OR anomaly_flags IS NULL OR anomaly_flags = ''
        """)

        assert zero_flags == 0, f"Found {zero_flags} anomalies with no flags"
        print("  All anomalies have flags: OK")

    def test_high_amount_flag(self, db_connection):
        """Validate HIGH_AMOUNT flag is applied correctly."""
        conn, db_type = db_connection
        high_amount_missing = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.payment_anomalies
            WHERE amount > 1000 AND anomaly_flags NOT LIKE '%HIGH_AMOUNT%'
        """)

        assert high_amount_missing == 0, \
            f"Found {high_amount_missing} high amount payments without HIGH_AMOUNT flag"
        print("  HIGH_AMOUNT flag: OK")

    def test_critical_risk_flag(self, db_connection):
        """Validate CRITICAL_RISK flag is applied correctly."""
        conn, db_type = db_connection
        critical_missing = execute_scalar(conn, db_type, """
            SELECT count(*) FROM fraud_analytics.payment_anomalies
            WHERE risk_level IN ('CRITICAL', 'HIGH') AND anomaly_flags NOT LIKE '%CRITICAL_RISK%'
        """)

        assert critical_missing == 0, \
            f"Found {critical_missing} critical/high risk payments without CRITICAL_RISK flag"
        print("  CRITICAL_RISK flag: OK")


class TestPhase6FinalValidation:
    """Phase 6: Final count validation."""

    def test_expected_counts(self, db_connection):
        """Validate expected counts are correct."""
        print("\n" + "="*50)
        print("PHASE 6: Final Count Validation")
        print("="*50)

        conn, db_type = db_connection
        counts = {}
        for table in ["payment_method_summary", "customer_payment_velocity",
                      "payment_anomalies", "fraud_risk_summary"]:
            count = execute_scalar(conn, db_type, f"""
                SELECT count(*) FROM fraud_analytics.{table}
            """)
            counts[table] = count
            print(f"  {table}: {count} rows")

        # Validate expected counts match source data
        expected_payment_methods = get_expected_payment_methods()
        expected_fraud_risk = get_expected_fraud_risk()
        expected_customers, _ = get_expected_velocity_counts()
        expected_anomalies = get_expected_anomaly_count()

        assert counts["payment_method_summary"] == len(expected_payment_methods), \
            f"payment_method_summary should have {len(expected_payment_methods)} rows, got {counts['payment_method_summary']}"
        assert counts["fraud_risk_summary"] == len(expected_fraud_risk), \
            f"fraud_risk_summary should have {len(expected_fraud_risk)} rows, got {counts['fraud_risk_summary']}"
        assert counts["customer_payment_velocity"] == expected_customers, \
            f"customer_payment_velocity should have {expected_customers} rows, got {counts['customer_payment_velocity']}"
        assert counts["payment_anomalies"] == expected_anomalies, \
            f"payment_anomalies should have {expected_anomalies} rows, got {counts['payment_anomalies']}"

        print("Final validation complete")
        print("Phase 6 PASSED")
