"""
Test verifier for Customer Risk Scoring task.
Supports both DuckDB and Snowflake backends.
"""

from __future__ import annotations

import subprocess
import os
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
    return 'risk_analytics'


SCHEMA = _get_schema()


# ============ CONFIGURATION ============


EXPECTED_TOTAL_CUSTOMERS = 1035
VALID_RISK_TIERS = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL']


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
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        result = run_cmd("dbt run --select stg_orders_risk stg_customers_risk customer_risk_scores")
    else:
        result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_risk_scores() -> List[Tuple]:
    """Query customer_risk_scores model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id,
                customer_name,
                late_payment_count,
                return_count,
                chargeback_count,
                risk_score,
                risk_tier
            FROM {SCHEMA}.customer_risk_scores
            ORDER BY customer_id
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
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def risk_rows(dbt_run) -> List[Tuple]:
    """Fixture that provides customer_risk_scores rows after dbt run."""
    return query_risk_scores()


class TestStructure:
    """Validate model structure and basic output."""

    def test_columns_exist(self, dbt_run):
        """Validate required columns exist."""
        actual_columns = get_table_columns(SCHEMA, 'customer_risk_scores')
        required = {
            "customer_id", "customer_name", "late_payment_count",
            "return_count", "chargeback_count", "risk_score", "risk_tier"
        }
        missing = required - actual_columns
        assert not missing, f"Missing columns: {missing}"
        print(f"All required columns present: {required}")

    def test_no_nulls(self, risk_rows):
        """Validate no NULL values."""
        for row in risk_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL value found in row: {row}"
        print(f"No NULL values found in {len(risk_rows)} rows")

    def test_customer_count(self, risk_rows):
        """Validate total customer count."""
        actual = len(risk_rows)
        assert actual == EXPECTED_TOTAL_CUSTOMERS, \
            f"Expected {EXPECTED_TOTAL_CUSTOMERS} customers, got {actual}"
        print(f"Customer count correct: {actual}")


class TestRiskCalculation:
    """Validate risk score calculations."""

    def test_risk_scores_non_negative(self, risk_rows):
        """Validate all risk scores are non-negative."""
        for row in risk_rows:
            risk_score = float(row[5])
            assert risk_score >= 0, f"Negative risk_score {risk_score} for customer {row[0]}"
        print("All risk scores are non-negative")

    def test_counts_non_negative(self, risk_rows):
        """Validate all counts are non-negative."""
        for row in risk_rows:
            late_payment = float(row[2])
            return_count = float(row[3])
            chargeback = float(row[4])
            assert late_payment >= 0, f"Negative late_payment_count for {row[0]}"
            assert return_count >= 0, f"Negative return_count for {row[0]}"
            assert chargeback >= 0, f"Negative chargeback_count for {row[0]}"
        print("All counts are non-negative")

    def test_risk_score_formula(self, risk_rows):
        """Validate risk score formula: (late*10) + (returns*5) + (chargebacks*20)."""
        for row in risk_rows:
            late_payment = float(row[2])
            return_count = float(row[3])
            chargeback = float(row[4])
            risk_score = float(row[5])
            expected = (late_payment * 10) + (return_count * 5) + (chargeback * 20)
            assert abs(risk_score - expected) < 0.01, \
                f"Risk score mismatch for {row[0]}: expected {expected}, got {risk_score}"
        print("Risk score formula verified for all customers")

    def test_risk_tiers_valid(self, risk_rows):
        """Validate all risk tiers are valid."""
        for row in risk_rows:
            tier = row[6]
            assert tier in VALID_RISK_TIERS, f"Invalid risk_tier '{tier}' for customer {row[0]}"
        print("All risk tiers are valid")

    def test_risk_tier_assignment(self, risk_rows):
        """Validate risk tier assignment based on score."""
        for row in risk_rows:
            risk_score = float(row[5])
            tier = row[6]
            if risk_score < 20:
                expected_tier = 'LOW'
            elif risk_score < 50:
                expected_tier = 'MEDIUM'
            elif risk_score < 100:
                expected_tier = 'HIGH'
            else:
                expected_tier = 'CRITICAL'
            assert tier == expected_tier, \
                f"Tier mismatch for {row[0]}: score={risk_score}, expected {expected_tier}, got {tier}"
        print("Risk tier assignment verified for all customers")


class TestDistribution:
    """Validate distribution of risk tiers."""

    def test_has_multiple_tiers(self, risk_rows):
        """Validate we have customers in multiple tiers."""
        tiers = set(row[6] for row in risk_rows)
        assert len(tiers) >= 2, f"Expected multiple risk tiers, got only: {tiers}"
        print(f"Multiple risk tiers present: {tiers}")

    def test_low_risk_majority(self, risk_rows):
        """Validate LOW risk is the majority (realistic expectation)."""
        low_count = sum(1 for row in risk_rows if row[6] == 'LOW')
        total = len(risk_rows)
        pct = low_count / total * 100
        assert pct > 50, f"Expected LOW risk to be majority, but only {pct:.1f}%"
        print(f"LOW risk customers: {low_count} ({pct:.1f}%)")


class TestIdempotency:
    """Validate idempotent execution."""

    def test_idempotency(self, risk_rows):
        """Validate re-running dbt produces same results."""
        rows_before = list(risk_rows)
        run_dbt_pipeline()
        rows_after = query_risk_scores()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
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
