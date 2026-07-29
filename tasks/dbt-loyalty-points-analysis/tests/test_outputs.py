"""
Test verifier for loyalty points program analytics task.
"""

import subprocess
import os
from collections import Counter
from typing import List, Tuple


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


EXPECTED_PROGRAM_COUNT = 2

REQUIRED_COLUMNS = {
    'program_id',
    'program_name',
    'member_count',
    'points_earned',
    'points_redeemed',
    'points_expired',
    'points_balance',
    'redemption_rate',
    'avg_points_per_member',
}

TOP_PROGRAMS = [
    ('e0582018-628c-47a5-b0dd-68f94ae5f05c', 'Premium Rewards', 489, 243835, 59975, 11161),
    ('c524285c-6d24-40ca-afa8-dd35af9b2e56', 'Rewards Plus', 485, 223159, 68109, 12559),
]


def run_cmd(cmd: str, cwd: str = None) -> subprocess.CompletedProcess:
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    run_cmd("dbt deps")
    result = run_cmd("dbt run --select stg_lp_transactions stg_lp_programs stg_lp_customers int_loyalty_metrics program_loyalty_summary")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_program_summary() -> List[Tuple]:
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                program_id,
                program_name,
                member_count,
                points_earned,
                points_redeemed,
                points_expired,
                points_balance,
                redemption_rate,
                avg_points_per_member
            FROM loyalty_analytics.program_loyalty_summary
            ORDER BY program_id
        """)
        return rows
    finally:
        conn.close()


def get_table_columns(schema: str, table: str) -> set:
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower(%s)
            AND lower(table_name) = lower(%s)
        """ if db_type == 'snowflake' else """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower(?)
            AND lower(table_name) = lower(?)
        """, [schema, table])
        return {c[0].lower() for c in cols}
    finally:
        conn.close()


import pytest


@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def program_rows(dbt_run) -> List[Tuple]:
    return query_program_summary()


class TestPhase1Structure:

    def test_required_columns_exist(self, dbt_run):
        """Verify program_loyalty_summary has all required columns."""
        actual_columns = get_table_columns('loyalty_analytics', 'program_loyalty_summary')
        missing = REQUIRED_COLUMNS - actual_columns
        assert not missing, f"Missing required columns: {missing}"

    def test_no_null_values(self, program_rows):
        """Verify no NULL values exist in any column of the summary."""
        null_found = []
        for row in program_rows:
            for i, val in enumerate(row):
                if val is None:
                    null_found.append((row[0], i))
        assert not null_found, f"NULL values found in {len(null_found)} cells"

    def test_unique_program_ids(self, program_rows):
        """Verify program_id values are unique with no duplicates."""
        program_ids = [row[0] for row in program_rows]
        duplicates = [pid for pid, count in Counter(program_ids).items() if count > 1]
        assert not duplicates, f"Duplicate program_ids found: {duplicates[:5]}"


class TestPhase2DataQuality:

    def test_program_count(self, program_rows):
        """Verify the expected number of loyalty programs exist."""
        actual_count = len(program_rows)
        assert actual_count == EXPECTED_PROGRAM_COUNT, \
            f"Expected {EXPECTED_PROGRAM_COUNT} programs, got {actual_count}"

    def test_positive_points_earned(self, program_rows):
        """Verify points_earned is non-negative for all programs."""
        invalid = []
        for row in program_rows:
            points_earned = int(float(row[3]))
            if points_earned < 0:
                invalid.append((row[0], points_earned))
        assert not invalid, f"Negative points_earned found: {invalid[:5]}"

    def test_positive_points_redeemed(self, program_rows):
        """Verify points_redeemed is non-negative for all programs."""
        invalid = []
        for row in program_rows:
            points_redeemed = int(float(row[4]))
            if points_redeemed < 0:
                invalid.append((row[0], points_redeemed))
        assert not invalid, f"Negative points_redeemed found: {invalid[:5]}"

    def test_valid_redemption_rate(self, program_rows):
        """Verify redemption_rate is between 0 and 100 for all programs."""
        invalid = []
        for row in program_rows:
            rate = float(row[7])
            if rate < 0 or rate > 100:
                invalid.append((row[0], rate))
        assert not invalid, f"Invalid redemption rates found: {invalid[:5]}"


class TestPhase3BusinessLogic:

    def test_balance_calculation(self, program_rows):
        """Verify points_balance equals earned minus redeemed minus expired."""
        violations = []
        for row in program_rows:
            earned = int(float(row[3]))
            redeemed = int(float(row[4]))
            expired = int(float(row[5]))
            balance = int(float(row[6]))
            expected_balance = earned - redeemed - expired
            if abs(balance - expected_balance) > 1:
                violations.append((row[0], balance, expected_balance))
        assert not violations, f"Balance calculation errors: {violations[:5]}"

    def test_redemption_rate_calculation(self, program_rows):
        """Verify redemption_rate equals 100 * redeemed / earned."""
        violations = []
        for row in program_rows:
            earned = float(row[3])
            redeemed = float(row[4])
            rate = float(row[7])
            if earned > 0:
                expected_rate = round(100.0 * redeemed / earned, 2)
                if abs(rate - expected_rate) > 0.1:
                    violations.append((row[0], rate, expected_rate))
        assert not violations, f"Redemption rate calculation errors: {violations[:5]}"

    def test_top_program_spot_checks(self, program_rows):
        """Spot-check top programs for expected member counts and point totals."""
        rows_by_id = {row[0]: row for row in program_rows}
        for prog_id, prog_name, expected_members, expected_earned, expected_redeemed, expected_expired in TOP_PROGRAMS:
            row = rows_by_id.get(prog_id)
            assert row is not None, f"Program {prog_id} not found"
            actual_members = int(float(row[2]))
            actual_earned = int(float(row[3]))
            actual_redeemed = int(float(row[4]))
            actual_expired = int(float(row[5]))
            assert actual_members == expected_members, \
                f"Program {prog_name}: expected {expected_members} members, got {actual_members}"
            assert actual_earned == expected_earned, \
                f"Program {prog_name}: expected {expected_earned} points earned, got {actual_earned}"
            assert actual_redeemed == expected_redeemed, \
                f"Program {prog_name}: expected {expected_redeemed} points redeemed, got {actual_redeemed}"
            assert actual_expired == expected_expired, \
                f"Program {prog_name}: expected {expected_expired} points expired, got {actual_expired}"


class TestPhase4Idempotency:

    def test_idempotency(self, program_rows):
        """Verify a second dbt run produces identical results."""
        rows_before = list(program_rows)
        run_dbt_pipeline()
        rows_after = query_program_summary()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare with float conversion for Decimal safety
            for i in range(len(before)):
                if before[i] is None and after[i] is None:
                    continue
                try:
                    assert float(before[i]) == float(after[i]), \
                        f"Row changed after re-run at column {i}: {before[i]} -> {after[i]}"
                except (TypeError, ValueError):
                    assert str(before[i]) == str(after[i]), \
                        f"Row changed after re-run at column {i}: {before[i]} -> {after[i]}"
