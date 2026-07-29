"""
Test verifier for customer geographic analysis task.
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
SCHEMA = "geographic_analytics"

EXPECTED_STATE_COUNT = 51

REQUIRED_COLUMNS = {
    'state_province',
    'customer_count',
    'order_count',
    'total_revenue',
    'avg_order_value',
    'revenue_per_customer',
    'orders_per_customer',
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ HELPERS ============


def run_cmd(cmd: str, cwd: str = PROJECT_DIR) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env['DBT_PROFILES_DIR'] = PROJECT_DIR
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, env=env)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    result = run_cmd("dbt deps || true")
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_state_customers() -> List[Tuple]:
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                state_province,
                customer_count,
                order_count,
                total_revenue,
                avg_order_value,
                revenue_per_customer,
                orders_per_customer
            FROM {SCHEMA}.fct_state_customers
            ORDER BY state_province
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
def state_rows(dbt_run) -> List[Tuple]:
    return query_state_customers()


class TestPhase1Structure:

    def test_required_columns_exist(self, dbt_run):
        """Verify fct_state_customers has all required columns."""
        actual_columns = get_table_columns('geographic_analytics', 'fct_state_customers')
        missing = REQUIRED_COLUMNS - actual_columns
        assert not missing, f"Missing required columns: {missing}"

    def test_no_null_values(self, state_rows):
        """Verify no NULL values exist in any column of the results."""
        null_found = []
        for row in state_rows:
            for i, val in enumerate(row):
                if val is None:
                    null_found.append((row[0], i))
        assert not null_found, f"NULL values found in {len(null_found)} cells"

    def test_unique_states(self, state_rows):
        """Verify state_province values are unique with no duplicates."""
        states = [row[0] for row in state_rows]
        duplicates = [s for s, count in Counter(states).items() if count > 1]
        assert not duplicates, f"Duplicate states found: {duplicates[:5]}"


class TestPhase2DataQuality:

    def test_state_count(self, state_rows):
        """Verify the expected number of states are present."""
        actual_count = len(state_rows)
        assert actual_count == EXPECTED_STATE_COUNT, \
            f"Expected {EXPECTED_STATE_COUNT} states, got {actual_count}"

    def test_non_negative_values(self, state_rows):
        """Verify customer_count, order_count, and total_revenue are non-negative."""
        invalid = []
        for row in state_rows:
            if int(row[1]) < 0 or int(row[2]) < 0 or float(row[3]) < 0:
                invalid.append(row[0])
        assert not invalid, f"Negative values found for states: {invalid[:5]}"

    def test_positive_customer_count(self, state_rows):
        """Verify each state has at least one customer."""
        invalid = []
        for row in state_rows:
            if int(row[1]) < 1:
                invalid.append((row[0], row[1]))
        assert not invalid, f"Invalid customer count found: {invalid[:5]}"


class TestPhase3BusinessLogic:

    def test_revenue_per_customer_calculation(self, state_rows):
        """Verify revenue_per_customer equals total_revenue divided by customer_count."""
        violations = []
        for row in state_rows:
            customer_count = int(row[1])
            revenue = float(row[3])
            rpc = float(row[5])
            if customer_count > 0:
                expected = round(revenue / customer_count, 2)
                if abs(rpc - expected) > 0.1:
                    violations.append((row[0], rpc, expected))
        assert not violations, f"Revenue per customer calculation errors: {violations[:5]}"

    def test_orders_per_customer_calculation(self, state_rows):
        """Verify orders_per_customer equals order_count divided by customer_count."""
        violations = []
        for row in state_rows:
            customer_count = int(row[1])
            order_count = int(row[2])
            opc = float(row[6])
            if customer_count > 0:
                expected = round(order_count / customer_count, 2)
                if abs(opc - expected) > 0.1:
                    violations.append((row[0], opc, expected))
        assert not violations, f"Orders per customer calculation errors: {violations[:5]}"


class TestPhase4Idempotency:

    def test_idempotency(self, state_rows):
        """Verify a second dbt run produces identical results."""
        rows_before = list(state_rows)
        run_dbt_pipeline()
        rows_after = query_state_customers()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            if before != after:
                for i, (b, a) in enumerate(zip(before, after)):
                    if b == a:
                        continue
                    try:
                        if abs(float(b) - float(a)) < 0.01:
                            continue
                    except (TypeError, ValueError):
                        pass
                    assert False, \
                        f"Row changed after re-run:\nBefore: {before}\nAfter: {after}"
