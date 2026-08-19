"""
Test verifier for Channel Revenue & Margin Monthly task.
Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate metric calculations and aggregation
  Phase 3: Validate dbt artifacts and model metadata
  Phase 4: Test idempotency (re-run produces same results)
"""
import json
import math
import os
import subprocess
from collections import Counter
from decimal import Decimal
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


def get_column_names(conn, db_type, query):
    """Execute a query and return column names from the result"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        cursor.execute(query)
        return [col[0].lower() for col in cursor.description]
    else:
        result = conn.execute(query)
        return [col[0].lower() for col in result.description]


# ============ HELPERS ============


MODEL_NAME = "ts_sales__channel_revenue_margin_monthly"
OUTPUT_COLUMNS = [
    "month_start",
    "sales_year",
    "sales_month",
    "channel_key",
    "channel_id",
    "channel_code",
    "channel_name",
    "channel_type",
    "order_count",
    "revenue",
    "profit",
    "discount_amount",
    "margin_rate",
    "avg_order_value",
    "discount_rate",
    "dbt_updated_at",
]
REQUIRED_COLUMNS = set(OUTPUT_COLUMNS)
KEY_COLUMNS = [
    "month_start",
    "sales_year",
    "sales_month",
    "channel_key",
    "channel_id",
    "channel_code",
    "channel_name",
    "channel_type",
]
MEASURE_COLUMNS = ["order_count", "revenue", "profit", "discount_amount"]
COL_INDEX = {name: idx for idx, name in enumerate(OUTPUT_COLUMNS)}
METRIC_TOLERANCE = 1e-6


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def get_manifest_path():
    """Get the manifest.json path based on DB_TYPE"""
    return Path(get_dbt_project_dir()) / "target" / "manifest.json"


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
    """Run dbt for the target model only."""
    result = run_cmd(
        "dbt run --select ts_sales__channel_revenue_margin_monthly --profiles-dir ./"
    )
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_connection():
    """Get database connection - returns (conn, db_type) tuple."""
    return get_db_connection()


def get_table_schema(conn, db_type, table_name):
    if db_type == 'snowflake':
        rows = execute_query(conn, db_type,
            """
            SELECT table_schema
            FROM information_schema.tables
            WHERE lower(table_name) = lower(%s)
            ORDER BY table_schema
            LIMIT 1
            """,
            [table_name],
        )
    else:
        rows = execute_query(conn, db_type,
            """
            SELECT table_schema
            FROM information_schema.tables
            WHERE lower(table_name) = lower(?)
            ORDER BY table_schema
            LIMIT 1
            """,
            [table_name],
        )
    if not rows:
        raise AssertionError(f"Table or view not found: {table_name}")
    return rows[0][0]


def qualified_table(conn, db_type, table_name):
    schema = get_table_schema(conn, db_type, table_name)
    if db_type == 'snowflake':
        # Use unquoted identifiers so Snowflake resolves them as uppercase
        return f'{schema}.{table_name}'
    else:
        return f'"{schema}"."{table_name}"'


def get_relation_type(conn, db_type, table_name):
    if db_type == 'snowflake':
        rows = execute_query(conn, db_type,
            """
            SELECT table_type
            FROM information_schema.tables
            WHERE lower(table_name) = lower(%s)
            ORDER BY table_schema
            LIMIT 1
            """,
            [table_name],
        )
    else:
        rows = execute_query(conn, db_type,
            """
            SELECT table_type
            FROM information_schema.tables
            WHERE lower(table_name) = lower(?)
            ORDER BY table_schema
            LIMIT 1
            """,
            [table_name],
        )
    if not rows:
        raise AssertionError(f"Table or view not found: {table_name}")
    return rows[0][0]


def to_float(value):
    if value is None:
        return None
    if isinstance(value, Decimal):
        return float(value)
    return float(value)


def normalize_value(value):
    if value is None:
        return None
    return str(value)


def row_key(month_start, channel_key):
    month_key = None if month_start is None else str(month_start)
    channel_key = None if channel_key is None else str(channel_key)
    return (month_key, channel_key)


def strip_updated_at(row):
    return row[:COL_INDEX["dbt_updated_at"]]


def assert_close(actual, expected, label):
    if expected is None:
        actual_f = to_float(actual) if actual is not None else None
        assert actual_f in (None, 0.0), f"{label} expected NULL/0, got {actual}"
        return
    actual_f = to_float(actual)
    expected_f = to_float(expected)
    assert actual_f is not None, f"{label} expected {expected_f}, got NULL"
    assert math.isclose(
        actual_f,
        expected_f,
        rel_tol=METRIC_TOLERANCE,
        abs_tol=METRIC_TOLERANCE,
    ), f"{label} expected {expected_f}, got {actual_f}"


def query_rows():
    conn, db_type = get_connection()
    try:
        table = qualified_table(conn, db_type, MODEL_NAME)
        rows = execute_query(conn, db_type,
            f"""
            SELECT
                month_start,
                sales_year,
                sales_month,
                channel_key,
                channel_id,
                channel_code,
                channel_name,
                channel_type,
                order_count,
                revenue,
                profit,
                discount_amount,
                margin_rate,
                avg_order_value,
                discount_rate,
                dbt_updated_at
            FROM {table}
            ORDER BY month_start, channel_key
            """
        )
        return rows
    finally:
        conn.close()


def validate_columns():
    conn, db_type = get_connection()
    try:
        schema = get_table_schema(conn, db_type, MODEL_NAME)
        if db_type == 'snowflake':
            cols = execute_query(conn, db_type,
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(%s)
                  AND lower(table_name) = lower(%s)
                """,
                [schema, MODEL_NAME],
            )
        else:
            cols = execute_query(conn, db_type,
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(?)
                  AND lower(table_name) = lower(?)
                """,
                [schema, MODEL_NAME],
            )
        col_names = {c[0].lower() for c in cols}
        missing = {c.lower() for c in REQUIRED_COLUMNS} - col_names
        assert not missing, f"Missing columns in {MODEL_NAME}: {missing}"
        print(f"All required columns present: {REQUIRED_COLUMNS}")
    finally:
        conn.close()


def count_month_mismatches():
    conn, db_type = get_connection()
    try:
        table = qualified_table(conn, db_type, MODEL_NAME)
        count = execute_scalar(conn, db_type,
            f"""
            SELECT count(*)
            FROM {table}
            WHERE month_start != date_trunc('month', month_start)
               OR extract(year FROM month_start) != sales_year
               OR extract(month FROM month_start) != sales_month
            """
        )
        return count
    finally:
        conn.close()


def load_manifest():
    manifest_path = get_manifest_path()
    if not manifest_path.exists():
        raise AssertionError(f"manifest.json not found at {manifest_path}")
    return json.loads(manifest_path.read_text())


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def output_rows(dbt_run):
    """Fixture that provides model rows after dbt run."""
    return query_rows()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_columns_exist(self, dbt_run):
        """Validate required columns exist."""
        print("\n" + "=" * 50)
        print("PHASE 1: Structure and Basic Validation")
        print("=" * 50)
        validate_columns()

    def test_relation_is_view(self, dbt_run):
        """Validate the model is materialized as a view."""
        conn, db_type = get_connection()
        try:
            relation_type = get_relation_type(conn, db_type, MODEL_NAME)
            assert relation_type.upper() == "VIEW", (
                f"Expected {MODEL_NAME} to be a VIEW, got {relation_type}"
            )
        finally:
            conn.close()

    def test_non_empty(self, output_rows):
        """Validate the model outputs rows."""
        assert output_rows, "Model returned zero rows"
        print(f"Model produced {len(output_rows)} rows")

    def test_month_fields_consistent(self, output_rows):
        """Validate month_start aligns with sales_year and sales_month. Requires non-empty output."""
        assert len(output_rows) > 0, "Cannot validate month fields: model returned zero rows"
        mismatch_count = count_month_mismatches()
        assert mismatch_count == 0, f"Found {mismatch_count} rows with month mismatch"

    def test_unique_grain(self, output_rows):
        """Validate one row per channel per month. Requires non-empty output."""
        assert len(output_rows) > 0, "Cannot validate grain: model returned zero rows"
        keys = [row_key(row[0], row[3]) for row in output_rows]
        duplicates = [key for key, count in Counter(keys).items() if count > 1]
        assert not duplicates, f"Duplicate month/channel combinations: {duplicates[:5]}"


class TestPhase2Data:
    """Phase 2: Validate metric calculations and aggregation."""

    def test_metric_formulas(self, output_rows):
        """Validate derived metrics match their definitions. Requires non-empty output."""
        print("\n" + "=" * 50)
        print("PHASE 2: Metric Validation")
        print("=" * 50)
        assert len(output_rows) > 0, "Cannot validate metrics: model returned zero rows"
        for row in output_rows:
            revenue = to_float(row[COL_INDEX["revenue"]])
            profit = to_float(row[COL_INDEX["profit"]])
            discount = to_float(row[COL_INDEX["discount_amount"]])
            order_count = row[COL_INDEX["order_count"]]

            expected_margin = None if not revenue else profit / revenue
            expected_aov = None if not order_count else revenue / order_count
            denom = None if revenue is None or discount is None else revenue + discount
            expected_discount_rate = None if not denom else discount / denom

            assert_close(
                row[COL_INDEX["margin_rate"]],
                expected_margin,
                f"margin_rate for {row_key(row[0], row[3])}",
            )
            assert_close(
                row[COL_INDEX["avg_order_value"]],
                expected_aov,
                f"avg_order_value for {row_key(row[0], row[3])}",
            )
            assert_close(
                row[COL_INDEX["discount_rate"]],
                expected_discount_rate,
                f"discount_rate for {row_key(row[0], row[3])}",
            )

    def test_metric_ranges(self, output_rows):
        """Validate metric values are within reasonable ranges. Requires non-empty output."""
        assert len(output_rows) > 0, "Cannot validate metric ranges: model returned zero rows"
        for row in output_rows:
            order_count = row[COL_INDEX["order_count"]]
            revenue = to_float(row[COL_INDEX["revenue"]])
            profit = to_float(row[COL_INDEX["profit"]])
            discount = to_float(row[COL_INDEX["discount_amount"]])
            margin_rate = to_float(row[COL_INDEX["margin_rate"]])
            discount_rate = to_float(row[COL_INDEX["discount_rate"]])
            avg_order_value = to_float(row[COL_INDEX["avg_order_value"]])

            assert order_count > 0, f"order_count must be > 0, got {order_count}"
            assert revenue is None or revenue >= 0, f"Negative revenue: {revenue}"
            assert discount is None or discount >= 0, f"Negative discount: {discount}"
            if avg_order_value is not None:
                assert avg_order_value >= 0, f"Negative AOV: {avg_order_value}"
            if margin_rate is not None:
                assert -1 <= margin_rate <= 1, f"Unusual margin_rate: {margin_rate}"
            if discount_rate is not None:
                assert 0 <= discount_rate <= 1, f"Invalid discount_rate: {discount_rate}"
            if profit is not None and revenue is not None:
                assert abs(profit) <= max(1.0, abs(revenue) * 2), (
                    f"Profit out of expected range: {profit}"
                )


    def test_revenue_reconciliation(self, output_rows):
        """Cross-check total revenue in model output against independently computed
        source totals from the raw fact tables. This catches models that produce
        self-consistent but incorrect numbers (e.g., wrong joins or filters).
        Requires non-empty output.
        """
        assert len(output_rows) > 0, "Cannot reconcile: model returned zero rows"
        model_total = sum(to_float(row[COL_INDEX["revenue"]]) or 0 for row in output_rows)
        conn, db_type = get_connection()
        try:
            fact_sales = qualified_table(conn, db_type, "dim_fact_sales")
            fact_values = qualified_table(conn, db_type, "stg_fact_sales")
            source_total = execute_scalar(conn, db_type,
                f"""
                SELECT sum(v.total_amount)
                FROM {fact_sales} f
                JOIN {fact_values} v ON f.sales_id = v.sale_key
                WHERE f.date_key IS NOT NULL
                """
            )
        finally:
            conn.close()
        source_total = float(source_total or 0)
        diff = abs(model_total - source_total)
        tolerance = max(source_total * 0.01, 1.0)
        assert diff <= tolerance, (
            f"Revenue reconciliation failed: model={model_total:.2f}, "
            f"source={source_total:.2f}, diff={diff:.2f}, tolerance={tolerance:.2f}"
        )


class TestPhase3DbtArtefacts:
    """Phase 3: Validate dbt artifacts and model metadata."""

    def test_manifest_metadata(self, dbt_run):
        """Validate model metadata in manifest.json."""
        print("\n" + "=" * 50)
        print("PHASE 3: dbt Artifact Validation")
        print("=" * 50)
        manifest = load_manifest()
        nodes = manifest.get("nodes", {})
        model_node = None
        for node in nodes.values():
            if node.get("resource_type") == "model" and node.get("name") == MODEL_NAME:
                model_node = node
                break
        assert model_node, f"Model {MODEL_NAME} not found in manifest.json"

        materialized = model_node.get("config", {}).get("materialized")
        assert materialized == "view", f"Expected materialized='view', got {materialized}"

        tags = set(model_node.get("tags") or [])
        assert {"time_series", "sales", "monthly", "channel"}.issubset(tags), (
            f"Expected tags to include 'time_series' and 'sales', got {sorted(tags)}"
        )


class TestPhase4Idempotency:
    """Phase 4: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, output_rows):
        """Test that re-running dbt produces the same results. Requires non-empty output."""
        print("\n" + "=" * 50)
        print("PHASE 4: Idempotency Test")
        print("=" * 50)

        assert len(output_rows) > 0, "Cannot test idempotency: model returned zero rows"

        rows_before = [strip_updated_at(row) for row in output_rows]

        run_dbt_pipeline()

        rows_after = [strip_updated_at(row) for row in query_rows()]

        assert len(rows_before) == len(rows_after), (
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"
        )

        for before, after in zip(rows_before, rows_after):
            assert before == after, (
                f"Row changed after re-run (excluding dbt_updated_at):\n"
                f"Before: {before}\nAfter: {after}"
            )

        print(f"Idempotency verified: {len(rows_after)} rows unchanged after re-run")
        print("Phase 4 PASSED")
