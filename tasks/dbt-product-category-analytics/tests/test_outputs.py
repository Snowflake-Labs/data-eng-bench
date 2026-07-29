"""
Test verifier for product category sales analytics task.
Supports both DuckDB and Snowflake backends.
"""

from __future__ import annotations

import subprocess
import os
from collections import Counter
from typing import List, Tuple
from pathlib import Path

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


def get_dbt_project_dir():
    """Get the dbt project directory"""
    return Path("/app/dbt_project")


# ============ SCHEMA CONFIGURATION ============


def _get_schema():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'sales_analytics'


SCHEMA = _get_schema()


# ============ CONFIGURATION ============


EXPECTED_CATEGORY_COUNT = 30

REQUIRED_COLUMNS = {
    'category_id',
    'category_name',
    'category_level',
    'total_orders',
    'total_units_sold',
    'total_revenue',
    'total_cost',
    'gross_profit',
    'profit_margin',
    'avg_order_value',
}

TOP_CATEGORIES = [
    ('9af47a6e-d198-4525-8a9d-99eb47f4c6c3', 'Skincare', 215, 413),
    ('cdf5d7f8-e11f-4cd0-a555-808b52955d54', 'Home & Kitchen', 213, 348),
    ('5a1c79e5-d9fa-4101-adba-9ae1dd493e38', 'Beauty & Personal Care', 212, 409),
]


# ============ HELPERS ============


def run_cmd(cmd: str) -> subprocess.CompletedProcess:
    cwd = str(get_dbt_project_dir())
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                                env={**os.environ, 'DBT_PROFILES_DIR': cwd})
    else:
        result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    run_cmd("dbt deps")  # ensure packages are installed
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_category_performance() -> List[Tuple]:
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                category_id,
                category_name,
                category_level,
                total_orders,
                total_units_sold,
                total_revenue,
                total_cost,
                gross_profit,
                profit_margin,
                avg_order_value
            FROM {SCHEMA}.fct_category_performance
            ORDER BY category_id
        """)
        return rows
    finally:
        conn.close()


def get_table_columns(schema: str, table: str) -> set:
    conn, db_type = get_db_connection()
    try:
        q = """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower(?)
            AND lower(table_name) = lower(?)
        """
        if db_type == 'snowflake':
            q = q.replace('?', '%s')
        cols = execute_query(conn, db_type, q, [schema, table])
        return {c[0].lower() for c in cols}
    finally:
        conn.close()


@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def category_rows(dbt_run) -> List[Tuple]:
    return query_category_performance()


class TestPhase1Structure:

    def test_required_columns_exist(self, dbt_run):
        """Verify fct_category_performance has all required columns."""
        actual_columns = get_table_columns(SCHEMA, 'fct_category_performance')
        missing = REQUIRED_COLUMNS - actual_columns
        assert not missing, f"Missing required columns: {missing}"

    def test_no_null_values(self, category_rows):
        """Verify no NULL values exist in any column of the results."""
        null_found = []
        for row in category_rows:
            for i, val in enumerate(row):
                if val is None:
                    null_found.append((row[0], i))
        assert not null_found, f"NULL values found in {len(null_found)} cells"

    def test_unique_category_ids(self, category_rows):
        """Verify category_id values are unique with no duplicates."""
        category_ids = [row[0] for row in category_rows]
        duplicates = [cid for cid, count in Counter(category_ids).items() if count > 1]
        assert not duplicates, f"Duplicate category_ids found: {duplicates[:5]}"


class TestPhase2DataQuality:

    def test_category_count(self, category_rows):
        """Verify the expected number of product categories exist."""
        actual_count = len(category_rows)
        assert actual_count == EXPECTED_CATEGORY_COUNT, \
            f"Expected {EXPECTED_CATEGORY_COUNT} categories, got {actual_count}"

    def test_positive_revenue(self, category_rows):
        """Verify total_revenue is non-negative for all categories."""
        invalid = []
        for row in category_rows:
            total_revenue = float(row[5])
            if total_revenue < 0:
                invalid.append((row[0], total_revenue))
        assert not invalid, f"Negative revenue found: {invalid[:5]}"

    def test_positive_units(self, category_rows):
        """Verify total_units_sold is at least 1 for all categories."""
        invalid = []
        for row in category_rows:
            total_units = int(row[4])
            if total_units < 1:
                invalid.append((row[0], total_units))
        assert not invalid, f"Invalid unit counts found: {invalid[:5]}"

    def test_valid_profit_margin(self, category_rows):
        """Verify profit_margin is between 0 and 1 for all categories."""
        invalid = []
        for row in category_rows:
            margin = float(row[8])
            if margin < 0 or margin > 1:
                invalid.append((row[0], margin))
        assert not invalid, f"Invalid profit margins found: {invalid[:5]}"


class TestPhase3BusinessLogic:

    def test_profit_calculation(self, category_rows):
        """Verify gross_profit equals total_revenue minus total_cost."""
        violations = []
        for row in category_rows:
            revenue = float(row[5])
            cost = float(row[6])
            profit = float(row[7])
            expected_profit = round(revenue - cost, 2)
            if abs(profit - expected_profit) > 0.01:
                violations.append((row[0], profit, expected_profit))
        assert not violations, f"Profit calculation errors: {violations[:5]}"

    def test_margin_calculation(self, category_rows):
        """Verify profit_margin equals gross_profit divided by total_revenue."""
        violations = []
        for row in category_rows:
            revenue = float(row[5])
            profit = float(row[7])
            margin = float(row[8])
            if revenue > 0:
                expected_margin = round(profit / revenue, 4)
                if abs(margin - expected_margin) > 0.001:
                    violations.append((row[0], margin, expected_margin))
        assert not violations, f"Margin calculation errors: {violations[:5]}"

    def test_top_category_spot_checks(self, category_rows):
        """Spot-check top categories for expected order counts and unit totals."""
        rows_by_id = {row[0]: row for row in category_rows}
        for cat_id, cat_name, expected_orders, expected_units in TOP_CATEGORIES:
            row = rows_by_id.get(cat_id)
            assert row is not None, f"Category {cat_id} not found"
            actual_orders = int(row[3])
            actual_units = int(row[4])
            assert actual_orders == expected_orders, \
                f"Category {cat_name}: expected {expected_orders} orders, got {actual_orders}"
            assert actual_units == expected_units, \
                f"Category {cat_name}: expected {expected_units} units, got {actual_units}"


class TestPhase4Idempotency:

    def test_idempotency(self, category_rows):
        """Verify a second dbt run produces identical results."""
        rows_before = list(category_rows)
        run_dbt_pipeline()
        rows_after = query_category_performance()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare with float conversion to handle numeric type differences
            for i in range(len(before)):
                b_val = before[i]
                a_val = after[i]
                if isinstance(b_val, (int, float)) or isinstance(a_val, (int, float)):
                    try:
                        assert abs(float(b_val) - float(a_val)) < 0.01, \
                            f"Value changed after re-run at column {i}: {b_val} -> {a_val}"
                    except (TypeError, ValueError):
                        assert b_val == a_val, f"Row changed after re-run"
                else:
                    assert str(b_val) == str(a_val), f"Row changed after re-run"
