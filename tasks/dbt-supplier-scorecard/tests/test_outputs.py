"""
Test verifier for Supplier Performance Scorecard task.
Supports both DuckDB and Snowflake backends.

Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate score calculations
  Phase 3: Validate composite score and tier assignments
  Phase 4: Validate metrics against source data
  Phase 5: Test idempotency (re-run produces same results)
"""

from __future__ import annotations

import subprocess
import os
from collections import Counter
from typing import List, Tuple, Dict
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


def get_dbt_project_dir():
    """Get the dbt project directory"""
    return Path("/app/dbt_project")


# ============ SCHEMA CONFIGURATION ============


def _get_schema():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'supplier_analytics'


SCHEMA = _get_schema()


# ============ EXPECTED VALUES ============

VALID_TIERS = ['PLATINUM', 'GOLD', 'SILVER', 'BRONZE', 'AT_RISK']
VALID_SUPPLIER_TYPES = ['MANUFACTURER', 'DISTRIBUTOR', 'WHOLESALER', 'DROPSHIP']


# ============ HELPERS ============


def run_cmd(cmd: str) -> subprocess.CompletedProcess:
    """Run a shell command and return the result."""
    cwd = str(get_dbt_project_dir())
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                                env={**os.environ, 'DBT_PROFILES_DIR': cwd})
    else:
        result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt run."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        result = run_cmd("dbt run --select +fct_supplier_metrics +fct_supplier_scorecard")
    else:
        result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_table_columns(schema: str, table: str) -> set:
    """Get column names for a table from information_schema."""
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


def query_supplier_metrics() -> List[Tuple]:
    """Query fct_supplier_metrics model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                supplier_id,
                supplier_code,
                supplier_name,
                supplier_type,
                total_pos,
                on_time_pos,
                on_time_delivery_rate,
                avg_days_late,
                total_quantity_received,
                total_quantity_accepted,
                total_quantity_rejected,
                overall_acceptance_rate,
                overall_defect_rate,
                total_po_value,
                total_invoice_value,
                overall_cost_variance,
                overall_cost_variance_pct
            FROM {SCHEMA}.fct_supplier_metrics
            ORDER BY supplier_code
        """)
        return rows
    finally:
        conn.close()


def query_supplier_scorecard() -> List[Tuple]:
    """Query fct_supplier_scorecard model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                supplier_id,
                supplier_code,
                supplier_name,
                supplier_type,
                on_time_delivery_rate,
                on_time_score,
                acceptance_rate,
                quality_score,
                cost_variance_pct,
                cost_score,
                composite_score,
                performance_tier
            FROM {SCHEMA}.fct_supplier_scorecard
            ORDER BY supplier_code
        """)
        return rows
    finally:
        conn.close()


# ============ SOURCE DATA QUERIES ============


def query_expected_delivery_metrics() -> Dict:
    """Calculate expected on-time delivery metrics from source data."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            WITH po_first_receipt AS (
                SELECT
                    po_id,
                    MIN(CAST(RECEIVED_AT AS DATE)) as first_receipt_date
                FROM PROCUREMENT.PURCHASE_ORDER_RECEIPTS
                GROUP BY po_id
            ),
            delivery_perf AS (
                SELECT
                    po.SUPPLIER_ID as supplier_id,
                    po.PO_ID,
                    po.EXPECTED_DATE,
                    pfr.first_receipt_date,
                    CASE WHEN pfr.first_receipt_date <= po.EXPECTED_DATE THEN 1 ELSE 0 END as is_on_time
                FROM PROCUREMENT.PURCHASE_ORDERS po
                JOIN po_first_receipt pfr ON po.PO_ID = pfr.po_id
                WHERE po.STATUS NOT IN ('DRAFT', 'CANCELLED')
            )
            SELECT
                s.SUPPLIER_ID as supplier_id,
                COUNT(*) as total_pos,
                SUM(is_on_time) as on_time_pos,
                ROUND(CAST(SUM(is_on_time) AS DOUBLE) / COUNT(*), 4) as on_time_delivery_rate
            FROM delivery_perf dp
            JOIN PROCUREMENT.SUPPLIERS s ON dp.supplier_id = s.SUPPLIER_ID
            WHERE s.STATUS = 'ACTIVE'
            GROUP BY s.SUPPLIER_ID
        """)
        return {row[0]: {'total_pos': row[1], 'on_time_pos': row[2], 'on_time_delivery_rate': float(row[3])} for row in rows}
    finally:
        conn.close()


def query_expected_quality_metrics() -> Dict:
    """Calculate expected quality metrics from source data."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            WITH receipt_totals AS (
                SELECT
                    r.PO_ID,
                    SUM(COALESCE(rl.QUANTITY_RECEIVED, 0)) as qty_received,
                    SUM(COALESCE(rl.QUANTITY_ACCEPTED, 0)) as qty_accepted,
                    SUM(COALESCE(rl.QUANTITY_REJECTED, 0)) as qty_rejected
                FROM PROCUREMENT.PURCHASE_ORDER_RECEIPTS r
                JOIN PROCUREMENT.PURCHASE_ORDER_RECEIPT_LINES rl ON r.RECEIPT_ID = rl.RECEIPT_ID
                GROUP BY r.PO_ID
            ),
            supplier_quality AS (
                SELECT
                    po.SUPPLIER_ID as supplier_id,
                    SUM(rt.qty_received) as total_received,
                    SUM(rt.qty_accepted) as total_accepted,
                    SUM(rt.qty_rejected) as total_rejected
                FROM PROCUREMENT.PURCHASE_ORDERS po
                JOIN receipt_totals rt ON po.PO_ID = rt.PO_ID
                WHERE po.STATUS NOT IN ('DRAFT', 'CANCELLED')
                GROUP BY po.SUPPLIER_ID
            )
            SELECT
                sq.supplier_id,
                sq.total_received,
                sq.total_accepted,
                ROUND(CAST(sq.total_accepted AS DOUBLE) / NULLIF(sq.total_received, 0), 4) as acceptance_rate
            FROM supplier_quality sq
            JOIN PROCUREMENT.SUPPLIERS s ON sq.supplier_id = s.SUPPLIER_ID
            WHERE s.STATUS = 'ACTIVE' AND sq.total_received > 0
        """)
        return {row[0]: {'total_received': float(row[1]), 'total_accepted': float(row[2]), 'acceptance_rate': float(row[3]) if row[3] else 0} for row in rows}
    finally:
        conn.close()


def query_expected_cost_metrics() -> Dict:
    """Calculate expected cost variance metrics from source data."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            WITH po_invoices AS (
                SELECT
                    PO_ID,
                    SUM(TOTAL_AMOUNT) as invoice_total
                FROM PROCUREMENT.SUPPLIER_INVOICES
                WHERE STATUS != 'DISPUTED'
                GROUP BY PO_ID
            ),
            supplier_costs AS (
                SELECT
                    po.SUPPLIER_ID as supplier_id,
                    SUM(po.TOTAL_AMOUNT) as total_po_value,
                    SUM(inv.invoice_total) as total_invoice_value
                FROM PROCUREMENT.PURCHASE_ORDERS po
                JOIN po_invoices inv ON po.PO_ID = inv.PO_ID
                WHERE po.STATUS NOT IN ('DRAFT', 'CANCELLED')
                  AND po.TOTAL_AMOUNT > 0
                GROUP BY po.SUPPLIER_ID
            )
            SELECT
                sc.supplier_id,
                sc.total_po_value,
                sc.total_invoice_value,
                ROUND((sc.total_invoice_value - sc.total_po_value) / sc.total_po_value, 4) as cost_variance_pct
            FROM supplier_costs sc
            JOIN PROCUREMENT.SUPPLIERS s ON sc.supplier_id = s.SUPPLIER_ID
            WHERE s.STATUS = 'ACTIVE'
        """)
        return {row[0]: {'total_po_value': float(row[1]), 'total_invoice_value': float(row[2]), 'cost_variance_pct': float(row[3]) if row[3] else 0} for row in rows}
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============


@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def metrics_rows(dbt_run) -> List[Tuple]:
    """Fixture that provides fct_supplier_metrics rows after dbt run."""
    return query_supplier_metrics()


@pytest.fixture(scope="module")
def scorecard_rows(dbt_run) -> List[Tuple]:
    """Fixture that provides fct_supplier_scorecard rows after dbt run."""
    return query_supplier_scorecard()


@pytest.fixture(scope="module")
def expected_delivery():
    """Fixture providing expected delivery metrics from source."""
    return query_expected_delivery_metrics()


@pytest.fixture(scope="module")
def expected_quality():
    """Fixture providing expected quality metrics from source."""
    return query_expected_quality_metrics()


@pytest.fixture(scope="module")
def expected_cost():
    """Fixture providing expected cost metrics from source."""
    return query_expected_cost_metrics()


# ============ PYTEST TEST FUNCTIONS ============


class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_metrics_columns_exist(self, dbt_run):
        """Validate required columns exist in fct_supplier_metrics."""
        print("\n" + "=" * 50)
        print("PHASE 1: Structure and Basic Validation")
        print("=" * 50)
        actual_columns = get_table_columns(SCHEMA, 'fct_supplier_metrics')
        required = {
            "supplier_id", "supplier_code", "supplier_name", "supplier_type",
            "total_pos", "on_time_pos", "on_time_delivery_rate", "avg_days_late",
            "total_quantity_received", "total_quantity_accepted", "total_quantity_rejected",
            "overall_acceptance_rate", "overall_defect_rate",
            "total_po_value", "total_invoice_value",
            "overall_cost_variance", "overall_cost_variance_pct"
        }
        missing = required - actual_columns
        assert not missing, f"Missing columns in fct_supplier_metrics: {missing}"
        print(f"All required columns present in fct_supplier_metrics: {required}")

    def test_scorecard_columns_exist(self, dbt_run):
        """Validate required columns exist in fct_supplier_scorecard."""
        actual_columns = get_table_columns(SCHEMA, 'fct_supplier_scorecard')
        required = {
            "supplier_id", "supplier_code", "supplier_name", "supplier_type",
            "on_time_delivery_rate", "on_time_score",
            "acceptance_rate", "quality_score",
            "cost_variance_pct", "cost_score",
            "composite_score", "performance_tier"
        }
        missing = required - actual_columns
        assert not missing, f"Missing columns in fct_supplier_scorecard: {missing}"
        print(f"All required columns present in fct_supplier_scorecard: {required}")

    def test_metrics_has_data(self, metrics_rows):
        """Validate fct_supplier_metrics has data."""
        assert len(metrics_rows) > 0, "fct_supplier_metrics has no data"
        print(f"fct_supplier_metrics has {len(metrics_rows)} rows")

    def test_scorecard_has_data(self, scorecard_rows):
        """Validate fct_supplier_scorecard has data."""
        assert len(scorecard_rows) > 0, "fct_supplier_scorecard has no data"
        print(f"fct_supplier_scorecard has {len(scorecard_rows)} rows")

    def test_unique_suppliers_in_metrics(self, metrics_rows):
        """Validate exactly one row per supplier in metrics."""
        supplier_ids = [row[0] for row in metrics_rows]
        duplicates = [sid for sid, count in Counter(supplier_ids).items() if count > 1]
        assert not duplicates, f"Duplicate supplier_ids found in metrics: {duplicates[:5]}"
        print(f"All {len(metrics_rows)} suppliers are unique in metrics")

    def test_unique_suppliers_in_scorecard(self, scorecard_rows):
        """Validate exactly one row per supplier in scorecard."""
        supplier_ids = [row[0] for row in scorecard_rows]
        duplicates = [sid for sid, count in Counter(supplier_ids).items() if count > 1]
        assert not duplicates, f"Duplicate supplier_ids found in scorecard: {duplicates[:5]}"
        print(f"All {len(scorecard_rows)} suppliers are unique in scorecard")


class TestPhase2Scores:
    """Phase 2: Validate score calculations."""

    def test_on_time_score_calculation(self, scorecard_rows):
        """Validate on_time_score = on_time_delivery_rate * 100."""
        print("\n" + "=" * 50)
        print("PHASE 2: Score Calculation Validation")
        print("=" * 50)
        for row in scorecard_rows:
            supplier_code = row[1]
            on_time_rate = float(row[4])
            on_time_score = float(row[5])
            expected_score = round(on_time_rate * 100, 2)
            assert abs(on_time_score - expected_score) < 0.1, \
                f"On-time score mismatch for {supplier_code}: expected {expected_score}, got {on_time_score}"
        print("All on_time_score calculations correct")

    def test_quality_score_calculation(self, scorecard_rows):
        """Validate quality_score = acceptance_rate * 100."""
        for row in scorecard_rows:
            supplier_code = row[1]
            acceptance_rate = float(row[6])
            quality_score = float(row[7])
            expected_score = round(acceptance_rate * 100, 2)
            assert abs(quality_score - expected_score) < 0.1, \
                f"Quality score mismatch for {supplier_code}: expected {expected_score}, got {quality_score}"
        print("All quality_score calculations correct")

    def test_cost_score_calculation(self, scorecard_rows):
        """Validate cost_score follows the linear interpolation rules."""
        for row in scorecard_rows:
            supplier_code = row[1]
            variance_pct = float(row[8]) if row[8] else 0
            cost_score = float(row[9]) if row[9] else 0

            # Calculate expected score
            if variance_pct <= -0.05:
                expected_score = 100.0
            elif variance_pct >= 0.10:
                expected_score = 0.0
            else:
                expected_score = max(0, min(100, 100.0 - ((variance_pct + 0.05) / 0.15) * 100.0))

            expected_score = round(expected_score, 2)
            assert abs(cost_score - expected_score) < 1.0, \
                f"Cost score mismatch for {supplier_code}: variance={variance_pct}, expected {expected_score}, got {cost_score}"
        print("All cost_score calculations correct")

    def test_delivery_rate_valid_range(self, metrics_rows):
        """Validate on_time_delivery_rate is between 0 and 1."""
        for row in metrics_rows:
            supplier_code = row[1]
            rate = float(row[6])
            assert 0 <= rate <= 1, \
                f"Invalid on_time_delivery_rate {rate} for {supplier_code}"
        print("All on_time_delivery_rate values in valid range (0-1)")

    def test_acceptance_rate_valid_range(self, metrics_rows):
        """Validate overall_acceptance_rate is between 0 and 1."""
        for row in metrics_rows:
            supplier_code = row[1]
            rate = float(row[11]) if row[11] else 0
            assert 0 <= rate <= 1, \
                f"Invalid overall_acceptance_rate {rate} for {supplier_code}"
        print("All overall_acceptance_rate values in valid range (0-1)")


class TestPhase3CompositeAndTiers:
    """Phase 3: Validate composite score and tier assignments."""

    def test_composite_score_calculation(self, scorecard_rows):
        """Validate composite score is weighted average of component scores."""
        print("\n" + "=" * 50)
        print("PHASE 3: Composite Score and Tier Validation")
        print("=" * 50)
        for row in scorecard_rows:
            supplier_code = row[1]
            on_time_score = float(row[5])
            quality_score = float(row[7])
            cost_score = float(row[9])
            composite_score = float(row[10])

            expected = round((on_time_score * 0.40) + (quality_score * 0.35) + (cost_score * 0.25), 2)
            assert abs(composite_score - expected) < 1.0, \
                f"Composite score mismatch for {supplier_code}: expected {expected}, got {composite_score}"
        print("All composite_score calculations correct")

    def test_performance_tier_assignment(self, scorecard_rows):
        """Validate performance tier is assigned correctly based on composite score."""
        for row in scorecard_rows:
            supplier_code = row[1]
            composite_score = float(row[10])
            tier = row[11]

            if composite_score >= 90:
                expected_tier = "PLATINUM"
            elif composite_score >= 75:
                expected_tier = "GOLD"
            elif composite_score >= 60:
                expected_tier = "SILVER"
            elif composite_score >= 40:
                expected_tier = "BRONZE"
            else:
                expected_tier = "AT_RISK"

            assert tier == expected_tier, \
                f"Tier mismatch for {supplier_code}: score={composite_score}, expected {expected_tier}, got {tier}"
        print("All performance_tier assignments correct")

    def test_valid_tiers(self, scorecard_rows):
        """Validate all tiers are valid."""
        for row in scorecard_rows:
            tier = row[11]
            assert tier in VALID_TIERS, f"Invalid tier '{tier}' for supplier {row[1]}"
        print("All tiers are valid")

    def test_tier_distribution(self, scorecard_rows):
        """Check tier distribution is reasonable."""
        tier_counts = Counter(row[11] for row in scorecard_rows)
        print(f"Tier distribution: {dict(tier_counts)}")
        # Just verify we have at least some variety
        assert len(tier_counts) >= 1, "Expected at least one tier to be present"


class TestPhase4SourceValidation:
    """Phase 4: Validate metrics against source data."""

    def test_on_time_delivery_rate_matches_source(self, metrics_rows, expected_delivery):
        """Validate on_time_delivery_rate matches calculation from source tables."""
        print("\n" + "=" * 50)
        print("PHASE 4: Source Data Validation")
        print("=" * 50)

        mismatches = []
        for row in metrics_rows:
            supplier_id = row[0]
            supplier_code = row[1]
            actual_total = int(row[4])
            actual_on_time = int(row[5])
            actual_rate = float(row[6])

            if supplier_id in expected_delivery:
                expected = expected_delivery[supplier_id]
                exp_total = int(expected['total_pos'])
                exp_on_time = int(expected['on_time_pos'])
                exp_rate = expected['on_time_delivery_rate']

                if actual_total != exp_total:
                    mismatches.append(f"{supplier_code}: total_pos expected {exp_total}, got {actual_total}")
                if actual_on_time != exp_on_time:
                    mismatches.append(f"{supplier_code}: on_time_pos expected {exp_on_time}, got {actual_on_time}")
                if abs(actual_rate - exp_rate) > 0.01:
                    mismatches.append(f"{supplier_code}: on_time_delivery_rate expected {exp_rate}, got {actual_rate}")

        assert not mismatches, f"Delivery metrics don't match source:\n" + "\n".join(mismatches[:10])
        print("All on_time_delivery_rate values match source data calculation")

    def test_acceptance_rate_matches_source(self, metrics_rows, expected_quality):
        """Validate overall_acceptance_rate matches calculation from source tables."""
        mismatches = []
        for row in metrics_rows:
            supplier_id = row[0]
            supplier_code = row[1]
            actual_received = float(row[8])
            actual_accepted = float(row[9])
            actual_rate = float(row[11])

            if supplier_id in expected_quality:
                expected = expected_quality[supplier_id]
                exp_received = expected['total_received']
                exp_accepted = expected['total_accepted']
                exp_rate = expected['acceptance_rate']

                if abs(actual_received - exp_received) > 0.01:
                    mismatches.append(f"{supplier_code}: total_received expected {exp_received}, got {actual_received}")
                if abs(actual_accepted - exp_accepted) > 0.01:
                    mismatches.append(f"{supplier_code}: total_accepted expected {exp_accepted}, got {actual_accepted}")
                if abs(actual_rate - exp_rate) > 0.01:
                    mismatches.append(f"{supplier_code}: acceptance_rate expected {exp_rate}, got {actual_rate}")

        assert not mismatches, f"Quality metrics don't match source:\n" + "\n".join(mismatches[:10])
        print("All overall_acceptance_rate values match source data calculation")

    def test_cost_variance_matches_source(self, metrics_rows, expected_cost):
        """Validate overall_cost_variance_pct matches calculation from source tables."""
        mismatches = []
        for row in metrics_rows:
            supplier_id = row[0]
            supplier_code = row[1]
            actual_po_value = float(row[13])
            actual_invoice_value = float(row[14])
            actual_variance_pct = float(row[16]) if row[16] is not None else 0.0

            if supplier_id in expected_cost:
                expected = expected_cost[supplier_id]
                exp_po_value = expected['total_po_value']
                exp_invoice_value = expected['total_invoice_value']
                exp_variance_pct = expected['cost_variance_pct']

                # Allow small tolerance for decimal differences
                if abs(actual_po_value - exp_po_value) > 1.0:
                    mismatches.append(f"{supplier_code}: total_po_value expected {exp_po_value}, got {actual_po_value}")
                if abs(actual_invoice_value - exp_invoice_value) > 1.0:
                    mismatches.append(f"{supplier_code}: total_invoice_value expected {exp_invoice_value}, got {actual_invoice_value}")
                if abs(actual_variance_pct - exp_variance_pct) > 0.01:
                    mismatches.append(f"{supplier_code}: cost_variance_pct expected {exp_variance_pct}, got {actual_variance_pct}")

        assert not mismatches, f"Cost metrics don't match source:\n" + "\n".join(mismatches[:10])
        print("All overall_cost_variance_pct values match source data calculation")


class TestPhase5Idempotency:
    """Phase 5: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, scorecard_rows):
        """Test that re-running dbt produces the same results."""
        print("\n" + "=" * 50)
        print("PHASE 5: Idempotency Test")
        print("=" * 50)

        # Store current results
        rows_before = list(scorecard_rows)

        # Re-run dbt
        run_dbt_pipeline()

        # Get new results
        rows_after = query_supplier_scorecard()

        # Compare
        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        # Compare row by row (sorted by supplier_code)
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

        print(f"Idempotency verified: {len(rows_after)} rows unchanged after re-run")
        print("Phase 5 PASSED")
