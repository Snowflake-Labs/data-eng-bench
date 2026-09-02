"""
Test verifier for customer order analytics task.
Validates dbt models in 4 phases: structure, data quality, business logic, idempotency.
"""

import os
import subprocess
from collections import Counter
from typing import List, Tuple

import pytest

# ============ CONFIGURATION ============

DB_PATH = "/app/database/retail.duckdb"
PROJECT_DIR = "/app/dbt_project"
SCHEMA = "customer_analytics"

EXPECTED_CUSTOMER_COUNT = 355
VALID_TIERS = ['VIP', 'Regular', 'New']

EXPECTED_TIER_COUNTS = {
    'VIP': (50, 65),
    'Regular': (45, 60),
    'New': (240, 260),
}

HIGH_VALUE_CUSTOMERS = [
    ('05e238d5-82ac-4683-baa3-b649026efd25', 233, 'VIP'),
    ('414ac645-cc7b-4613-9d3a-9b3e974d3c7a', 206, 'VIP'),
    ('bc248555-7d59-48ef-8f3f-7cb746d9a245', 69, 'VIP'),
]

REQUIRED_COLUMNS = {
    'customer_id',
    'customer_name',
    'email',
    'order_count',
    'total_spend',
    'avg_order_value',
    'first_order_date',
    'last_order_date',
    'days_since_last_order',
    'customer_tier',
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
            schema=SCHEMA,
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', DB_PATH)
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

    # Clean up any previous conflicting relations (DuckDB only)
    if db_type == 'duckdb':
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', DB_PATH)
        conn = duckdb.connect(db_path, read_only=False)
        try:
            for schema_name in ("customer_analytics", "CUSTOMER_ANALYTICS"):
                for rel in ("stg_customers", "stg_orders", "int_customer_order_metrics", "dim_customer_tiers"):
                    for ddl in (
                        f"DROP VIEW IF EXISTS {schema_name}.{rel}",
                        f"DROP TABLE IF EXISTS {schema_name}.{rel}",
                    ):
                        try:
                            conn.execute(ddl)
                        except Exception:
                            pass
        finally:
            conn.close()

    result = run_cmd("dbt run --select +dim_customer_tiers --full-refresh")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_customer_tiers() -> List[Tuple]:
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id,
                customer_name,
                email,
                order_count,
                total_spend,
                avg_order_value,
                first_order_date,
                last_order_date,
                days_since_last_order,
                customer_tier
            FROM {SCHEMA}.dim_customer_tiers
            ORDER BY customer_id
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
def customer_rows(dbt_run) -> List[Tuple]:
    return query_customer_tiers()


class TestPhase1Structure:

    def test_required_columns_exist(self, dbt_run):
        """Verify all required columns exist in dim_customer_tiers."""
        actual_columns = get_table_columns('customer_analytics', 'dim_customer_tiers')
        missing = REQUIRED_COLUMNS - actual_columns
        assert not missing, f"Missing required columns: {missing}"

    def test_no_null_values(self, customer_rows):
        """Ensure no NULL values exist in any column of the customer tiers data."""
        null_found = []
        for row in customer_rows:
            for i, val in enumerate(row):
                if val is None:
                    null_found.append((row[0], i))
        assert not null_found, f"NULL values found in {len(null_found)} cells"

    def test_unique_customer_ids(self, customer_rows):
        """Check that each customer_id appears exactly once (no duplicates)."""
        customer_ids = [row[0] for row in customer_rows]
        duplicates = [cid for cid, count in Counter(customer_ids).items() if count > 1]
        assert not duplicates, f"Duplicate customer_ids found: {duplicates[:5]}"


class TestPhase2DataQuality:

    def test_customer_count(self, customer_rows):
        """Verify the total number of customers matches the expected count."""
        actual_count = len(customer_rows)
        assert actual_count == EXPECTED_CUSTOMER_COUNT, \
            f"Expected {EXPECTED_CUSTOMER_COUNT} customers, got {actual_count}"

    def test_valid_tier_values(self, customer_rows):
        """Ensure all customer_tier values are in the allowed set (VIP, Regular, New)."""
        invalid_tiers = []
        for row in customer_rows:
            tier = row[9]
            if tier not in VALID_TIERS:
                invalid_tiers.append((row[0], tier))
        assert not invalid_tiers, f"Invalid tier values found: {invalid_tiers[:5]}"

    def test_positive_monetary_values(self, customer_rows):
        """Check that total_spend and avg_order_value are strictly positive."""
        invalid = []
        for row in customer_rows:
            total_spend = float(row[4])
            avg_order_value = float(row[5])
            if total_spend <= 0 or avg_order_value <= 0:
                invalid.append((row[0], total_spend, avg_order_value))
        assert not invalid, f"Non-positive monetary values found: {invalid[:5]}"

    def test_order_count_positive(self, customer_rows):
        """Ensure every customer has at least one order."""
        invalid = []
        for row in customer_rows:
            order_count = int(row[3])
            if order_count < 1:
                invalid.append((row[0], order_count))
        assert not invalid, f"Invalid order counts found: {invalid[:5]}"


class TestPhase3BusinessLogic:

    def test_tier_threshold_vip(self, customer_rows):
        """Validate VIP tier is assigned if and only if order_count >= 5."""
        violations = []
        for row in customer_rows:
            order_count = int(row[3])
            tier = row[9]
            if tier == 'VIP' and order_count < 5:
                violations.append((row[0], order_count, tier, "VIP with < 5 orders"))
            if order_count >= 5 and tier != 'VIP':
                violations.append((row[0], order_count, tier, "5+ orders not VIP"))
        assert not violations, f"VIP tier threshold violations: {violations[:5]}"

    def test_tier_threshold_regular(self, customer_rows):
        """Validate Regular tier is assigned if and only if order_count is 3 or 4."""
        violations = []
        for row in customer_rows:
            order_count = int(row[3])
            tier = row[9]
            if tier == 'Regular' and not (3 <= order_count < 5):
                violations.append((row[0], order_count, tier, "Regular not in 3-4 range"))
            if 3 <= order_count < 5 and tier != 'Regular':
                violations.append((row[0], order_count, tier, "3-4 orders not Regular"))
        assert not violations, f"Regular tier threshold violations: {violations[:5]}"

    def test_tier_threshold_new(self, customer_rows):
        """Validate New tier is assigned if and only if order_count is 1 or 2."""
        violations = []
        for row in customer_rows:
            order_count = int(row[3])
            tier = row[9]
            if tier == 'New' and not (1 <= order_count < 3):
                violations.append((row[0], order_count, tier, "New not in 1-2 range"))
            if 1 <= order_count < 3 and tier != 'New':
                violations.append((row[0], order_count, tier, "1-2 orders not New"))
        assert not violations, f"New tier threshold violations: {violations[:5]}"

    def test_tier_distribution(self, customer_rows):
        """Check that the count of customers per tier falls within expected ranges."""
        tier_counts = Counter(row[9] for row in customer_rows)
        for tier, (min_count, max_count) in EXPECTED_TIER_COUNTS.items():
            actual = tier_counts.get(tier, 0)
            assert min_count <= actual <= max_count, \
                f"Tier '{tier}' count {actual} outside expected range ({min_count}, {max_count})"

    def test_high_value_customer_spot_checks(self, customer_rows):
        """Spot-check specific high-value customers for correct order counts and tiers."""
        rows_by_id = {row[0]: row for row in customer_rows}
        for cust_id, expected_orders, expected_tier in HIGH_VALUE_CUSTOMERS:
            row = rows_by_id.get(cust_id)
            assert row is not None, f"High-value customer {cust_id} not found"
            actual_orders = int(row[3])
            actual_tier = row[9]
            assert actual_orders == expected_orders, \
                f"Customer {cust_id[:8]}: expected {expected_orders} orders, got {actual_orders}"
            assert actual_tier == expected_tier, \
                f"Customer {cust_id[:8]}: expected tier '{expected_tier}', got '{actual_tier}'"


class TestPhase4Idempotency:

    def test_idempotency(self, customer_rows):
        """Verify that re-running the dbt pipeline produces identical results."""
        rows_before = list(customer_rows)
        run_dbt_pipeline()
        rows_after = query_customer_tiers()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare with float() for Snowflake Decimal compatibility
            for i in range(len(before)):
                b_val = before[i]
                a_val = after[i]
                if isinstance(b_val, (int, float)) or (b_val is not None and hasattr(b_val, '__float__')):
                    assert float(b_val) == float(a_val), f"Row changed after re-run at column {i}"
                else:
                    assert str(b_val) == str(a_val), f"Row changed after re-run at column {i}"
