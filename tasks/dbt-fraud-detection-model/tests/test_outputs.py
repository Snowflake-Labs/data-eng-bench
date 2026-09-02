"""
Test verifier for Fraud Detection Model task.
Multi-phase testing:
  Phase 1: Validate model structure and required columns
  Phase 2: Validate fraud flag calculations
  Phase 3: Validate risk level assignments
  Phase 4: Test idempotency
"""
import subprocess
import os
from collections import Counter
from pathlib import Path
import json
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


# ============ CONSTANTS ============

REQUIRED_COLUMNS = [
    "order_id", "customer_id", "ordered_at", "grand_total", "total_items",
    "orders_same_day", "billing_state", "shipping_state", "is_high_value",
    "is_bulk_order", "is_velocity_fraud", "is_address_mismatch",
    "is_first_order_high_value", "has_chargeback_history",
    "fraud_flags_count", "fraud_risk_level"
]

VALID_RISK_LEVELS = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'NONE']


# ============ HELPERS ============


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


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
    """Run dbt run."""
    result = run_cmd("dbt run --select +fraud_flagged_orders")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_source_table(table_name):
    """Get the fully qualified source table name based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        mapping = {
            'orders': 'ORDERS.ORDERS',
            'ORDER_LINES': 'ORDERS.ORDER_LINES',
            'ADDRESSES': 'RAW_SFDC.ADDRESSES',
        }
        return mapping.get(table_name, f'main.{table_name}')
    else:
        return f'main.{table_name}'


def get_expected_order_count():
    """Get the expected order count from source data."""
    conn, db_type = get_db_connection()
    try:
        orders_table = get_source_table('orders')
        result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {orders_table}")
        return int(result)
    finally:
        conn.close()


def query_fraud_orders():
    """Query fraud_flagged_orders model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                order_id,
                customer_id,
                ordered_at,
                grand_total,
                total_items,
                orders_same_day,
                billing_state,
                shipping_state,
                is_high_value,
                is_bulk_order,
                is_velocity_fraud,
                is_address_mismatch,
                is_first_order_high_value,
                has_chargeback_history,
                fraud_flags_count,
                fraud_risk_level
            FROM fraud_analytics.fraud_flagged_orders
            ORDER BY order_id
        """)
        return rows
    finally:
        conn.close()


def query_source_orders():
    """Query source orders for validation."""
    conn, db_type = get_db_connection()
    try:
        orders_table = get_source_table('orders')
        addresses_table = get_source_table('ADDRESSES')
        order_lines_table = get_source_table('ORDER_LINES')

        rows = execute_query(conn, db_type, f"""
            SELECT
                o.ORDER_ID,
                o.CUSTOMER_ID,
                o.GRAND_TOTAL,
                o.CHARGEBACK_FLAG,
                o.IS_FIRST_ORDER,
                o.ORDERED_AT,
                ba.STATE_PROVINCE as billing_state,
                sa.STATE_PROVINCE as shipping_state,
                COALESCE(ol_agg.total_items, 0) as total_items
            FROM {orders_table} o
            LEFT JOIN {addresses_table} ba ON o.BILLING_ADDRESS_ID = ba.ADDRESS_ID
            LEFT JOIN {addresses_table} sa ON o.SHIPPING_ADDRESS_ID = sa.ADDRESS_ID
            LEFT JOIN (
                SELECT ORDER_ID, SUM(QUANTITY_ORDERED) as total_items
                FROM {order_lines_table}
                GROUP BY ORDER_ID
            ) ol_agg ON o.ORDER_ID = ol_agg.ORDER_ID
            ORDER BY o.ORDER_ID
        """)
        return rows
    finally:
        conn.close()


def to_bool(val):
    """Convert a value to boolean, handling Snowflake Decimal/VARCHAR returns."""
    if val is None:
        return False
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return bool(val)
    # Handle Decimal
    try:
        return bool(int(val))
    except (ValueError, TypeError):
        pass
    # Handle string
    if isinstance(val, str):
        return val.upper() in ('TRUE', '1', 'T', 'Y', 'YES')
    return bool(val)


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def fraud_rows(dbt_run):
    """Fixture that provides fraud_flagged_orders rows after dbt run."""
    return query_fraud_orders()


@pytest.fixture(scope="module")
def source_rows():
    """Fixture that provides source order data for validation."""
    return query_source_orders()


@pytest.fixture(scope="module")
def expected_order_count():
    """Fixture for expected order count."""
    return get_expected_order_count()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_columns_exist(self, dbt_run):
        """Validate required columns exist in fraud_flagged_orders."""
        print("\n" + "="*50)
        print("PHASE 1: Structure and Basic Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'fraud_analytics'
                AND lower(table_name) = 'fraud_flagged_orders'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {c.lower() for c in REQUIRED_COLUMNS}
            missing = required - col_names
            assert not missing, f"Missing columns in fraud_flagged_orders: {missing}"
            print(f"All required columns present: {required}")
        finally:
            conn.close()

    def test_order_count(self, fraud_rows, expected_order_count):
        """Validate all orders are included."""
        actual = len(fraud_rows)
        assert actual == expected_order_count, \
            f"Expected {expected_order_count} orders, got {actual}. Model should include ALL orders."
        print(f"Order count correct: {actual}")

    def test_unique_orders(self, fraud_rows):
        """Validate exactly one row per order."""
        order_ids = [row[0] for row in fraud_rows]
        duplicates = [oid for oid, count in Counter(order_ids).items() if count > 1]
        assert not duplicates, f"Duplicate order_ids found: {duplicates[:5]}"
        print(f"All {len(fraud_rows)} orders are unique")


class TestPhase2FraudFlags:
    """Phase 2: Validate fraud flag calculations."""

    def test_high_value_flag(self, fraud_rows):
        """Validate is_high_value flag calculation."""
        print("\n" + "="*50)
        print("PHASE 2: Fraud Flag Validation")
        print("="*50)

        for row in fraud_rows:
            grand_total = float(row[3])
            is_high_value = to_bool(row[8])
            expected = grand_total > 1500
            assert is_high_value == expected, \
                f"Order {row[0]}: grand_total={grand_total}, is_high_value={is_high_value}, expected={expected}"
        print("is_high_value flag correctly calculated")

    def test_bulk_order_flag(self, fraud_rows):
        """Validate is_bulk_order flag calculation."""
        for row in fraud_rows:
            total_items = float(row[4])
            is_bulk_order = to_bool(row[9])
            expected = total_items > 5
            assert is_bulk_order == expected, \
                f"Order {row[0]}: total_items={total_items}, is_bulk_order={is_bulk_order}, expected={expected}"
        print("is_bulk_order flag correctly calculated")

    def test_velocity_fraud_flag(self, fraud_rows):
        """Validate is_velocity_fraud flag calculation."""
        for row in fraud_rows:
            orders_same_day = int(row[5])
            is_velocity_fraud = to_bool(row[10])
            expected = orders_same_day >= 2
            assert is_velocity_fraud == expected, \
                f"Order {row[0]}: orders_same_day={orders_same_day}, is_velocity_fraud={is_velocity_fraud}, expected={expected}"
        print("is_velocity_fraud flag correctly calculated")

    def test_address_mismatch_flag(self, fraud_rows):
        """Validate is_address_mismatch flag calculation."""
        for row in fraud_rows:
            billing_state = row[6]
            shipping_state = row[7]
            is_address_mismatch = to_bool(row[11])

            # Should be FALSE if either is NULL
            if billing_state is None or shipping_state is None:
                expected = False
            else:
                # Handle trimming for comparison
                bs = str(billing_state).strip() if billing_state else None
                ss = str(shipping_state).strip() if shipping_state else None
                if bs is None or ss is None or bs == '' or ss == '':
                    expected = False
                else:
                    expected = bs != ss

            assert is_address_mismatch == expected, \
                f"Order {row[0]}: billing={billing_state}, shipping={shipping_state}, mismatch={is_address_mismatch}, expected={expected}"
        print("is_address_mismatch flag correctly calculated (NULL handling verified)")

    def test_first_order_high_value_flag(self, fraud_rows, source_rows):
        """Validate is_first_order_high_value flag calculation."""
        # Build lookup from source data
        source_lookup = {str(row[0]).strip(): row for row in source_rows}

        for row in fraud_rows:
            order_id = str(row[0]).strip()
            grand_total = float(row[3])
            is_first_order_high_value = to_bool(row[12])

            source = source_lookup.get(order_id)
            if source:
                is_first_order = to_bool(source[4])  # IS_FIRST_ORDER from source
                expected = is_first_order and (grand_total > 500)
                assert is_first_order_high_value == expected, \
                    f"Order {order_id}: is_first_order={is_first_order}, grand_total={grand_total}, " \
                    f"is_first_order_high_value={is_first_order_high_value}, expected={expected}"
        print("is_first_order_high_value flag correctly calculated")

    def test_fraud_flags_count(self, fraud_rows):
        """Validate fraud_flags_count is sum of all flags."""
        for row in fraud_rows:
            is_high_value = 1 if to_bool(row[8]) else 0
            is_bulk_order = 1 if to_bool(row[9]) else 0
            is_velocity_fraud = 1 if to_bool(row[10]) else 0
            is_address_mismatch = 1 if to_bool(row[11]) else 0
            is_first_order_high_value = 1 if to_bool(row[12]) else 0
            has_chargeback_history = 1 if to_bool(row[13]) else 0

            expected_count = (is_high_value + is_bulk_order + is_velocity_fraud +
                            is_address_mismatch + is_first_order_high_value + has_chargeback_history)
            actual_count = int(row[14])
            assert actual_count == expected_count, \
                f"Order {row[0]}: flags_count={actual_count}, expected={expected_count}"
        print("fraud_flags_count correctly calculated")


class TestPhase3RiskLevels:
    """Phase 3: Validate risk level assignments."""

    def test_risk_levels_valid(self, fraud_rows):
        """Validate all risk levels are valid."""
        print("\n" + "="*50)
        print("PHASE 3: Risk Level Validation")
        print("="*50)

        for row in fraud_rows:
            risk_level = str(row[15]).strip()
            assert risk_level in VALID_RISK_LEVELS, \
                f"Invalid risk level '{risk_level}' for order {row[0]}"
        print("All risk levels are valid")

    def test_risk_level_calculation(self, fraud_rows):
        """Validate risk level based on flags_count."""
        for row in fraud_rows:
            flags_count = int(row[14])
            risk_level = str(row[15]).strip()

            if flags_count >= 4:
                expected = 'CRITICAL'
            elif flags_count == 3:
                expected = 'HIGH'
            elif flags_count == 2:
                expected = 'MEDIUM'
            elif flags_count == 1:
                expected = 'LOW'
            else:
                expected = 'NONE'

            assert risk_level == expected, \
                f"Order {row[0]}: flags_count={flags_count}, risk_level={risk_level}, expected={expected}"
        print("Risk levels correctly calculated based on flags_count")

    def test_risk_level_distribution(self, fraud_rows):
        """Validate risk levels are reasonably distributed."""
        risk_counts = Counter(str(row[15]).strip() for row in fraud_rows)
        print(f"Risk level distribution: {dict(risk_counts)}")

        # Majority of orders should be NONE or LOW risk
        safe_count = risk_counts.get('NONE', 0) + risk_counts.get('LOW', 0)
        assert safe_count > len(fraud_rows) * 0.5, \
            "Expected majority of orders to be NONE or LOW risk"
        print("Risk level distribution is reasonable")


class TestPhase4Idempotency:
    """Phase 4: Test idempotency."""

    def test_idempotency(self, fraud_rows):
        """Test that re-running dbt produces the same results."""
        print("\n" + "="*50)
        print("PHASE 4: Idempotency Test")
        print("="*50)

        rows_before = list(fraud_rows)

        # Re-run dbt
        run_dbt_pipeline()

        # Get new results
        rows_after = query_fraud_orders()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare element by element with type normalization
            for i in range(len(before)):
                b_val = before[i]
                a_val = after[i]
                # Normalize numeric types for comparison
                if b_val is not None and a_val is not None:
                    try:
                        if float(b_val) == float(a_val):
                            continue
                    except (ValueError, TypeError):
                        pass
                if str(b_val).strip() != str(a_val).strip():
                    assert False, \
                        f"Row changed after re-run:\nBefore: {before}\nAfter: {after}"

        print(f"Idempotency verified: {len(rows_after)} rows unchanged after re-run")
