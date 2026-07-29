"""
Test verifier for warehouse inventory analysis task.
Validates dbt models in 4 phases: structure, data quality, business logic, idempotency.
"""

import subprocess
import os
from collections import Counter
from typing import List, Tuple

import pytest


EXPECTED_WAREHOUSE_COUNT = 5

REQUIRED_COLUMNS = {
    'warehouse_id',
    'warehouse_name',
    'warehouse_type',
    'city',
    'state_province',
    'total_quantity',
    'inventory_value',
    'distinct_product_count',
    'avg_unit_cost',
    'max_single_item_value',
    'inventory_concentration',
}

# Column index mapping for the SELECT query
COL_WAREHOUSE_ID = 0
COL_WAREHOUSE_NAME = 1
COL_WAREHOUSE_TYPE = 2
COL_CITY = 3
COL_STATE_PROVINCE = 4
COL_TOTAL_QUANTITY = 5
COL_INVENTORY_VALUE = 6
COL_DISTINCT_PRODUCT_COUNT = 7
COL_AVG_UNIT_COST = 8
COL_MAX_SINGLE_ITEM_VALUE = 9
COL_INVENTORY_CONCENTRATION = 10


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
            schema='inventory_analytics',
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


# ============ HELPERS ============


def run_cmd(cmd: str, cwd: str = "/app/dbt_project") -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_warehouse_inventory() -> List[Tuple]:
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                warehouse_id,
                warehouse_name,
                warehouse_type,
                city,
                state_province,
                total_quantity,
                inventory_value,
                distinct_product_count,
                avg_unit_cost,
                max_single_item_value,
                inventory_concentration
            FROM inventory_analytics.fct_warehouse_inventory
            ORDER BY warehouse_id
        """)
        return rows
    finally:
        conn.close()


def get_table_columns(schema: str, table: str) -> set:
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(%s)
                AND lower(table_name) = lower(%s)
            """, [schema, table])
        else:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(?)
                AND lower(table_name) = lower(?)
            """, [schema, table])
        return {c[0].lower() for c in cols}
    finally:
        conn.close()


@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def inventory_rows(dbt_run) -> List[Tuple]:
    return query_warehouse_inventory()


class TestPhase1Structure:

    def test_required_columns_exist(self, dbt_run):
        actual_columns = get_table_columns('inventory_analytics', 'fct_warehouse_inventory')
        missing = REQUIRED_COLUMNS - actual_columns
        assert not missing, f"Missing required columns: {missing}"

    def test_no_null_values(self, inventory_rows):
        col_names = [
            'warehouse_id', 'warehouse_name', 'warehouse_type', 'city',
            'state_province', 'total_quantity', 'inventory_value',
            'distinct_product_count', 'avg_unit_cost',
            'max_single_item_value', 'inventory_concentration'
        ]
        null_found = []
        for row in inventory_rows:
            for i, val in enumerate(row):
                if val is None:
                    null_found.append((row[COL_WAREHOUSE_ID], col_names[i]))
        assert not null_found, f"NULL values found: {null_found}"

    def test_unique_warehouse_ids(self, inventory_rows):
        warehouse_ids = [row[COL_WAREHOUSE_ID] for row in inventory_rows]
        duplicates = [wid for wid, count in Counter(warehouse_ids).items() if count > 1]
        assert not duplicates, f"Duplicate warehouse_ids found: {duplicates[:5]}"


class TestPhase2DataQuality:

    def test_warehouse_count(self, inventory_rows):
        actual_count = len(inventory_rows)
        assert actual_count == EXPECTED_WAREHOUSE_COUNT, \
            f"Expected {EXPECTED_WAREHOUSE_COUNT} warehouses, got {actual_count}"

    def test_non_negative_quantity(self, inventory_rows):
        invalid = []
        for row in inventory_rows:
            if row[COL_TOTAL_QUANTITY] < 0:
                invalid.append((row[COL_WAREHOUSE_ID], row[COL_TOTAL_QUANTITY]))
        assert not invalid, f"Negative quantity found: {invalid[:5]}"

    def test_non_negative_value(self, inventory_rows):
        invalid = []
        for row in inventory_rows:
            if float(row[COL_INVENTORY_VALUE]) < 0:
                invalid.append((row[COL_WAREHOUSE_ID], row[COL_INVENTORY_VALUE]))
        assert not invalid, f"Negative inventory value found: {invalid[:5]}"

    def test_non_negative_avg_cost(self, inventory_rows):
        invalid = []
        for row in inventory_rows:
            if float(row[COL_AVG_UNIT_COST]) < 0:
                invalid.append((row[COL_WAREHOUSE_ID], row[COL_AVG_UNIT_COST]))
        assert not invalid, f"Negative avg unit cost found: {invalid[:5]}"

    def test_distinct_product_count_positive(self, inventory_rows):
        invalid = []
        for row in inventory_rows:
            if int(row[COL_DISTINCT_PRODUCT_COUNT]) <= 0:
                invalid.append((row[COL_WAREHOUSE_ID], row[COL_DISTINCT_PRODUCT_COUNT]))
        assert not invalid, f"Non-positive distinct_product_count: {invalid[:5]}"

    def test_max_single_item_value_positive(self, inventory_rows):
        invalid = []
        for row in inventory_rows:
            if float(row[COL_MAX_SINGLE_ITEM_VALUE]) <= 0:
                invalid.append((row[COL_WAREHOUSE_ID], row[COL_MAX_SINGLE_ITEM_VALUE]))
        assert not invalid, f"Non-positive max_single_item_value: {invalid[:5]}"

    def test_inventory_concentration_range(self, inventory_rows):
        """Inventory concentration must be between 0 (exclusive) and 1 (inclusive)."""
        invalid = []
        for row in inventory_rows:
            conc = float(row[COL_INVENTORY_CONCENTRATION])
            if conc <= 0 or conc > 1:
                invalid.append((row[COL_WAREHOUSE_ID], conc))
        assert not invalid, (
            f"inventory_concentration out of range (0, 1]: {invalid[:5]}"
        )


class TestPhase3BusinessLogic:

    def test_positive_inventory_values(self, inventory_rows):
        for row in inventory_rows:
            assert row[COL_TOTAL_QUANTITY] > 0, f"Warehouse {row[COL_WAREHOUSE_ID]} has no inventory"
            assert float(row[COL_INVENTORY_VALUE]) > 0, f"Warehouse {row[COL_WAREHOUSE_ID]} has no inventory value"


class TestPhase3StricterValidation:
    """Stricter tests that cross-validate model output against source tables."""

    def test_aggregation_total_quantity_matches_source(self, dbt_run):
        """Query source tables directly and verify total_quantity matches
        SUM(quantity_on_hand) from source for each warehouse (where quantity_on_hand > 0)."""
        conn, db_type = get_db_connection()
        try:
            # Get total_quantity per warehouse from the model
            model_rows = execute_query(conn, db_type, """
                SELECT warehouse_id, total_quantity
                FROM inventory_analytics.fct_warehouse_inventory
                ORDER BY warehouse_id
            """)
            model_map = {str(r[0]).strip(): int(r[1]) for r in model_rows}

            # Get SUM(quantity_on_hand) per warehouse from source tables directly
            source_rows = execute_query(conn, db_type, """
                SELECT trim(il.warehouse_id), SUM(il.quantity_on_hand)
                FROM INVENTORY.INVENTORY_LEVELS il
                WHERE il.quantity_on_hand > 0
                GROUP BY trim(il.warehouse_id)
                ORDER BY trim(il.warehouse_id)
            """)
            source_map = {str(r[0]).strip(): int(r[1]) for r in source_rows}

            # Every warehouse in the model must match source aggregation
            mismatches = []
            for wid, model_qty in model_map.items():
                source_qty = source_map.get(wid)
                if source_qty is None:
                    mismatches.append(f"Warehouse {wid}: in model but not in source")
                elif model_qty != source_qty:
                    mismatches.append(
                        f"Warehouse {wid}: model total_quantity={model_qty}, "
                        f"source SUM(quantity_on_hand)={source_qty}"
                    )
            assert not mismatches, (
                f"total_quantity mismatch between model and source:\n"
                + "\n".join(mismatches)
            )
        finally:
            conn.close()

    def test_formula_inventory_value_matches_source(self, dbt_run):
        """For each warehouse, verify inventory_value = SUM(quantity_on_hand * unit_cost)
        from source data. Tolerance: 0.01."""
        conn, db_type = get_db_connection()
        try:
            # Get inventory_value per warehouse from the model
            model_rows = execute_query(conn, db_type, """
                SELECT warehouse_id, inventory_value
                FROM inventory_analytics.fct_warehouse_inventory
                ORDER BY warehouse_id
            """)
            model_map = {str(r[0]).strip(): float(r[1]) for r in model_rows}

            # Get SUM(quantity_on_hand * unit_cost) per warehouse from source
            source_rows = execute_query(conn, db_type, """
                SELECT trim(il.warehouse_id),
                       ROUND(SUM(il.quantity_on_hand * il.unit_cost), 2)
                FROM INVENTORY.INVENTORY_LEVELS il
                WHERE il.quantity_on_hand > 0
                GROUP BY trim(il.warehouse_id)
                ORDER BY trim(il.warehouse_id)
            """)
            source_map = {str(r[0]).strip(): float(r[1]) for r in source_rows}

            assert len(model_map) >= 3, (
                f"Expected at least 3 warehouses in model, got {len(model_map)}"
            )

            mismatches = []
            for wid, model_val in model_map.items():
                source_val = source_map.get(wid)
                if source_val is None:
                    mismatches.append(f"Warehouse {wid}: in model but not in source")
                elif abs(model_val - source_val) > 0.01:
                    mismatches.append(
                        f"Warehouse {wid}: model inventory_value={model_val}, "
                        f"source SUM(qty*cost)={source_val}"
                    )
            assert not mismatches, (
                f"inventory_value formula mismatch:\n" + "\n".join(mismatches)
            )
        finally:
            conn.close()

    def test_formula_avg_unit_cost_is_weighted_average(self, inventory_rows):
        """Verify avg_unit_cost = inventory_value / total_quantity for each row.
        This is the weighted average: SUM(unit_cost * quantity_on_hand) / SUM(quantity_on_hand).
        Tolerance: 0.01."""
        mismatches = []
        for row in inventory_rows:
            wid = row[COL_WAREHOUSE_ID]
            total_qty = int(row[COL_TOTAL_QUANTITY])
            inv_value = float(row[COL_INVENTORY_VALUE])
            avg_cost = float(row[COL_AVG_UNIT_COST])

            if total_qty == 0:
                mismatches.append(f"Warehouse {wid}: total_quantity is 0, cannot compute weighted avg")
                continue

            expected_avg = round(inv_value / total_qty, 2)
            if abs(avg_cost - expected_avg) > 0.01:
                mismatches.append(
                    f"Warehouse {wid}: avg_unit_cost={avg_cost}, "
                    f"expected inventory_value/total_quantity={expected_avg}"
                )
        assert not mismatches, (
            f"avg_unit_cost is not a proper weighted average:\n"
            + "\n".join(mismatches)
        )

    def test_distinct_product_count_matches_source(self, dbt_run):
        """Verify distinct_product_count = COUNT(DISTINCT variant_id)
        from source for each warehouse (where quantity_on_hand > 0)."""
        conn, db_type = get_db_connection()
        try:
            model_rows = execute_query(conn, db_type, """
                SELECT warehouse_id, distinct_product_count
                FROM inventory_analytics.fct_warehouse_inventory
                ORDER BY warehouse_id
            """)
            model_map = {str(r[0]).strip(): int(r[1]) for r in model_rows}

            source_rows = execute_query(conn, db_type, """
                SELECT trim(il.warehouse_id), COUNT(DISTINCT il.variant_id)
                FROM INVENTORY.INVENTORY_LEVELS il
                WHERE il.quantity_on_hand > 0
                GROUP BY trim(il.warehouse_id)
                ORDER BY trim(il.warehouse_id)
            """)
            source_map = {str(r[0]).strip(): int(r[1]) for r in source_rows}

            mismatches = []
            for wid, model_cnt in model_map.items():
                source_cnt = source_map.get(wid)
                if source_cnt is None:
                    mismatches.append(f"Warehouse {wid}: in model but not in source")
                elif model_cnt != source_cnt:
                    mismatches.append(
                        f"Warehouse {wid}: model distinct_product_count={model_cnt}, "
                        f"source COUNT(DISTINCT variant_id)={source_cnt}"
                    )
            assert not mismatches, (
                f"distinct_product_count mismatch:\n" + "\n".join(mismatches)
            )
        finally:
            conn.close()

    def test_max_single_item_value_matches_source(self, dbt_run):
        """Verify max_single_item_value = MAX(quantity_on_hand * unit_cost)
        from source for each warehouse. Tolerance: 0.01."""
        conn, db_type = get_db_connection()
        try:
            model_rows = execute_query(conn, db_type, """
                SELECT warehouse_id, max_single_item_value
                FROM inventory_analytics.fct_warehouse_inventory
                ORDER BY warehouse_id
            """)
            model_map = {str(r[0]).strip(): float(r[1]) for r in model_rows}

            source_rows = execute_query(conn, db_type, """
                SELECT trim(il.warehouse_id),
                       ROUND(MAX(il.quantity_on_hand * il.unit_cost), 2)
                FROM INVENTORY.INVENTORY_LEVELS il
                WHERE il.quantity_on_hand > 0
                GROUP BY trim(il.warehouse_id)
                ORDER BY trim(il.warehouse_id)
            """)
            source_map = {str(r[0]).strip(): float(r[1]) for r in source_rows}

            mismatches = []
            for wid, model_val in model_map.items():
                source_val = source_map.get(wid)
                if source_val is None:
                    mismatches.append(f"Warehouse {wid}: in model but not in source")
                elif abs(model_val - source_val) > 0.01:
                    mismatches.append(
                        f"Warehouse {wid}: model max_single_item_value={model_val}, "
                        f"source MAX(qty*cost)={source_val}"
                    )
            assert not mismatches, (
                f"max_single_item_value mismatch:\n" + "\n".join(mismatches)
            )
        finally:
            conn.close()

    def test_inventory_concentration_formula(self, inventory_rows):
        """Verify inventory_concentration = max_single_item_value / inventory_value.
        Tolerance: 0.0001 (since concentration is rounded to 4 decimal places)."""
        mismatches = []
        for row in inventory_rows:
            wid = row[COL_WAREHOUSE_ID]
            inv_value = float(row[COL_INVENTORY_VALUE])
            max_item = float(row[COL_MAX_SINGLE_ITEM_VALUE])
            concentration = float(row[COL_INVENTORY_CONCENTRATION])

            if inv_value == 0:
                mismatches.append(f"Warehouse {wid}: inventory_value is 0")
                continue

            expected_conc = round(max_item / inv_value, 4)
            if abs(concentration - expected_conc) > 0.0001:
                mismatches.append(
                    f"Warehouse {wid}: inventory_concentration={concentration}, "
                    f"expected max_single_item_value/inventory_value={expected_conc}"
                )
        assert not mismatches, (
            f"inventory_concentration formula mismatch:\n" + "\n".join(mismatches)
        )

    def test_max_single_item_value_le_inventory_value(self, inventory_rows):
        """max_single_item_value cannot exceed inventory_value for any warehouse."""
        violations = []
        for row in inventory_rows:
            wid = row[COL_WAREHOUSE_ID]
            inv_value = float(row[COL_INVENTORY_VALUE])
            max_item = float(row[COL_MAX_SINGLE_ITEM_VALUE])
            if max_item > inv_value + 0.01:
                violations.append(
                    f"Warehouse {wid}: max_single_item_value={max_item} > "
                    f"inventory_value={inv_value}"
                )
        assert not violations, (
            f"max_single_item_value exceeds inventory_value:\n" + "\n".join(violations)
        )

    def test_source_reconciliation_total_inventory_value(self, dbt_run):
        """Cross-check: sum of all inventory_value across warehouses in the model
        must equal SUM(quantity_on_hand * unit_cost) across all source records
        where quantity_on_hand > 0. Tolerance: 0.01."""
        conn, db_type = get_db_connection()
        try:
            model_rows = execute_query(conn, db_type, """
                SELECT ROUND(SUM(inventory_value), 2)
                FROM inventory_analytics.fct_warehouse_inventory
            """)
            model_total = float(model_rows[0][0])

            source_rows = execute_query(conn, db_type, """
                SELECT ROUND(SUM(il.quantity_on_hand * il.unit_cost), 2)
                FROM INVENTORY.INVENTORY_LEVELS il
                WHERE il.quantity_on_hand > 0
            """)
            source_total = float(source_rows[0][0])

            assert abs(model_total - source_total) <= 0.01, (
                f"Total inventory value mismatch: model={model_total}, "
                f"source={source_total}, diff={abs(model_total - source_total)}"
            )
        finally:
            conn.close()

    def test_no_zero_total_quantity_rows(self, inventory_rows):
        """Verify no rows appear with total_quantity = 0, since we filter
        quantity_on_hand > 0 from source."""
        zero_qty = [row[COL_WAREHOUSE_ID] for row in inventory_rows if int(row[COL_TOTAL_QUANTITY]) == 0]
        assert not zero_qty, (
            f"Rows with total_quantity=0 found for warehouses: {zero_qty}. "
            f"These should be excluded since we filter quantity_on_hand > 0."
        )

    def test_monetary_rounding_two_decimal_places(self, inventory_rows):
        """Verify inventory_value, avg_unit_cost, and max_single_item_value
        have at most 2 decimal places."""
        rounding_issues = []
        for row in inventory_rows:
            wid = row[COL_WAREHOUSE_ID]
            inv_value = float(row[COL_INVENTORY_VALUE])
            avg_cost = float(row[COL_AVG_UNIT_COST])
            max_item = float(row[COL_MAX_SINGLE_ITEM_VALUE])

            if abs(inv_value - round(inv_value, 2)) > 1e-9:
                rounding_issues.append(
                    f"Warehouse {wid}: inventory_value={inv_value} has more than 2 decimal places"
                )
            if abs(avg_cost - round(avg_cost, 2)) > 1e-9:
                rounding_issues.append(
                    f"Warehouse {wid}: avg_unit_cost={avg_cost} has more than 2 decimal places"
                )
            if abs(max_item - round(max_item, 2)) > 1e-9:
                rounding_issues.append(
                    f"Warehouse {wid}: max_single_item_value={max_item} has more than 2 decimal places"
                )
        assert not rounding_issues, (
            f"Monetary values not properly rounded to 2 decimal places:\n"
            + "\n".join(rounding_issues)
        )

    def test_concentration_rounding_four_decimal_places(self, inventory_rows):
        """Verify inventory_concentration has at most 4 decimal places."""
        rounding_issues = []
        for row in inventory_rows:
            wid = row[COL_WAREHOUSE_ID]
            conc = float(row[COL_INVENTORY_CONCENTRATION])
            if abs(conc - round(conc, 4)) > 1e-9:
                rounding_issues.append(
                    f"Warehouse {wid}: inventory_concentration={conc} has more than 4 decimal places"
                )
        assert not rounding_issues, (
            f"Concentration values not properly rounded to 4 decimal places:\n"
            + "\n".join(rounding_issues)
        )

    def test_warehouse_id_uniqueness(self, inventory_rows):
        """Verify warehouse_id is unique with no duplicates."""
        warehouse_ids = [str(row[COL_WAREHOUSE_ID]).strip() for row in inventory_rows]
        seen = set()
        duplicates = []
        for wid in warehouse_ids:
            if wid in seen:
                duplicates.append(wid)
            seen.add(wid)
        assert not duplicates, (
            f"Duplicate warehouse_id values found: {duplicates}"
        )


class TestPhase4Idempotency:

    def test_idempotency(self, inventory_rows):
        rows_before = list(inventory_rows)
        run_dbt_pipeline()
        rows_after = query_warehouse_inventory()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            assert before == after, f"Row changed after re-run"
