"""
Test verifier for monthly channel ROI and payback model.
Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate data accuracy and metric calculations
  Phase 3: Validate dbt artifacts and dependencies
  Phase 4: Test idempotency (re-run produces same results)
"""
import json
import math
import os
import subprocess
from collections import Counter, defaultdict
from datetime import date, datetime
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ CONSTANTS ============

MODEL_NAME = "rpt_channel_roi_payback_monthly"
MODEL_NAMES = [MODEL_NAME]

REQUIRED_COLUMNS = [
    "month_start",
    "channel_key",
    "channel_name",
    "channel_type",
    "segment_name",
    "tier_name",
    "impressions",
    "clicks",
    "conversions",
    "ctr",
    "conversion_rate",
    "spend_amount",
    "revenue_attributed",
    "roas",
    "sales_revenue",
    "sales_profit",
    "order_count",
    "order_conversion_rate",
    "new_customers",
    "total_new_customers",
    "new_customer_share",
    "blended_cac",
    "ltv_90d_revenue_per_customer",
    "ltv_90d_profit_per_customer",
    "payback_90d_profit_ratio",
]

NUMERIC_COLUMNS = {
    "channel_key",
    "impressions",
    "clicks",
    "conversions",
    "ctr",
    "conversion_rate",
    "spend_amount",
    "revenue_attributed",
    "roas",
    "sales_revenue",
    "sales_profit",
    "order_count",
    "order_conversion_rate",
    "new_customers",
    "total_new_customers",
    "new_customer_share",
    "blended_cac",
    "ltv_90d_revenue_per_customer",
    "ltv_90d_profit_per_customer",
    "payback_90d_profit_ratio",
}

INT_COLUMNS = {
    "channel_key",
    "impressions",
    "clicks",
    "conversions",
    "order_count",
    "new_customers",
    "total_new_customers",
}

DATE_COLUMNS = {"month_start"}

EXPECTED_DIR = Path(__file__).resolve().parent / "expected"

ALLOWED_REFS = {
    "stg_fact_marketing_spend",
    "stg_analytics__dim_date",
    "stg_analytics__fact_sales",
    "stg_analytics__dim_customer",
    "stg_analytics__dim_channel",
}

MODEL_SPECS = {
    MODEL_NAME: {
        "required_columns": REQUIRED_COLUMNS,
        "numeric_columns": NUMERIC_COLUMNS,
        "int_columns": INT_COLUMNS,
        "key_columns": ["month_start", "channel_key", "segment_name", "tier_name"],
        "expected_json": EXPECTED_DIR / "rpt_channel_roi_payback_monthly.json",
        "allowed_refs": ALLOWED_REFS,
    }
}

NUMERIC_TOLERANCES = {
    "ctr": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "conversion_rate": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "roas": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "order_conversion_rate": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "new_customer_share": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "blended_cac": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "ltv_90d_revenue_per_customer": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "ltv_90d_profit_per_customer": {"rel_tol": 1e-4, "abs_tol": 1e-6},
    "payback_90d_profit_ratio": {"rel_tol": 1e-4, "abs_tol": 1e-6},
}

EPSILON = 1e-9


# ============ HELPERS ============

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
    """Run dbt for the ROI payback model."""
    run_cmd("dbt deps")
    result = run_cmd(f"dbt run --select {MODEL_NAME} --profiles-dir .")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_table_identifier(conn, db_type, table_name):
    if db_type == 'snowflake':
        rows = execute_query(conn, db_type, """
            SELECT table_schema, table_name
            FROM information_schema.tables
            WHERE lower(table_name) = lower(%s)
            ORDER BY table_schema
            LIMIT 1
        """, [table_name])
    else:
        rows = execute_query(conn, db_type, """
            SELECT table_schema, table_name
            FROM information_schema.tables
            WHERE lower(table_name) = lower(?)
            ORDER BY table_schema
            LIMIT 1
        """, [table_name])
    if not rows:
        raise AssertionError(f"Table or view not found: {table_name}")
    return rows[0][0], rows[0][1]


def qualified_table(conn, db_type, table_name):
    schema, actual_name = get_table_identifier(conn, db_type, table_name)
    return f'"{schema}"."{actual_name}"'


def get_table_schema(conn, db_type, table_name):
    schema, _ = get_table_identifier(conn, db_type, table_name)
    return schema


def get_relation_type(conn, db_type, table_name):
    if db_type == 'snowflake':
        rows = execute_query(conn, db_type, """
            SELECT table_type
            FROM information_schema.tables
            WHERE lower(table_name) = lower(%s)
            ORDER BY table_schema
            LIMIT 1
        """, [table_name])
    else:
        rows = execute_query(conn, db_type, """
            SELECT table_type
            FROM information_schema.tables
            WHERE lower(table_name) = lower(?)
            ORDER BY table_schema
            LIMIT 1
        """, [table_name])
    if not rows:
        raise AssertionError(f"Table or view not found: {table_name}")
    return rows[0][0]


def to_float(value):
    if value is None:
        return None
    if isinstance(value, Decimal):
        return float(value)
    return float(value)


def normalize_timestamp(value):
    if value is None:
        return None
    if isinstance(value, (datetime, date)):
        return value.strftime("%Y-%m-%d")
    value_str = str(value)
    return value_str[:10]


def normalize_row(row, numeric_columns, int_columns):
    normalized = {}
    for key, value in row.items():
        key_lower = key.lower()
        if key_lower in DATE_COLUMNS:
            normalized[key_lower] = normalize_timestamp(value)
            continue
        if key_lower in int_columns:
            normalized[key_lower] = None if value is None else int(value)
            continue
        if key_lower in numeric_columns:
            normalized[key_lower] = None if value is None else to_float(value)
            continue
        normalized[key_lower] = None if value is None else str(value)
    return normalized


def normalize_rows(rows, numeric_columns, int_columns):
    return [normalize_row(row, numeric_columns, int_columns) for row in rows]


def load_expected_rows(path, numeric_columns, int_columns):
    raw = json.loads(Path(path).read_text())
    if isinstance(raw, dict):
        if len(raw) != 1:
            raise AssertionError(f"Expected one top-level key in {path}")
        rows = next(iter(raw.values()))
    else:
        rows = raw
    return normalize_rows(rows, numeric_columns, int_columns)


def fetch_rows(table_name):
    conn, db_type = get_db_connection()
    try:
        qualified = qualified_table(conn, db_type, table_name)
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {qualified}")
            columns = [desc[0] for desc in cursor.description]
            rows = cursor.fetchall()
        else:
            cur = conn.execute(f"SELECT * FROM {qualified}")
            columns = [desc[0] for desc in cur.description]
            rows = cur.fetchall()
        return [dict(zip(columns, row)) for row in rows]
    finally:
        conn.close()


def fetch_model_rows(table_name, numeric_columns, int_columns):
    rows = fetch_rows(table_name)
    return normalize_rows(rows, numeric_columns, int_columns)


def index_rows(rows, key_columns):
    index = {}
    for row in rows:
        key = tuple(row.get(col) for col in key_columns)
        if key in index:
            raise AssertionError(f"Duplicate key found: {key}")
        index[key] = row
    return index


def is_null(value):
    if value is None:
        return True
    return isinstance(value, float) and math.isnan(value)


def assert_numeric_close(actual, expected, rel_tol=1e-6, abs_tol=1e-6):
    if is_null(expected):
        assert is_null(actual), f"Expected null, got {actual}"
        return
    assert not is_null(actual), f"Expected value, got null"
    assert math.isclose(float(actual), float(expected), rel_tol=rel_tol, abs_tol=abs_tol), (
        f"Numeric mismatch: {actual} != {expected}"
    )


def assert_row_matches(actual, expected, numeric_columns, int_columns):
    for key, expected_value in expected.items():
        assert key in actual, f"Missing column in output: {key}"
        actual_value = actual.get(key)
        if key in int_columns:
            if is_null(expected_value):
                assert is_null(actual_value), f"Expected null for {key}, got {actual_value}"
            else:
                assert int(actual_value) == int(expected_value), (
                    f"Mismatch for {key}: {actual_value} != {expected_value}"
                )
            continue
        if key in numeric_columns:
            tolerances = NUMERIC_TOLERANCES.get(key, {})
            assert_numeric_close(actual_value, expected_value, **tolerances)
            continue
        if is_null(expected_value):
            assert is_null(actual_value), f"Expected null for {key}, got {actual_value}"
        else:
            assert str(actual_value) == str(expected_value), (
                f"Mismatch for {key}: {actual_value} != {expected_value}"
            )


def assert_rows_match(actual_rows, expected_rows, key_columns, numeric_columns, int_columns):
    actual_index = index_rows(actual_rows, key_columns)
    expected_index = index_rows(expected_rows, key_columns)

    if actual_index.keys() != expected_index.keys():
        missing = expected_index.keys() - actual_index.keys()
        extra = actual_index.keys() - expected_index.keys()
        print(f"Row key mismatch details: missing_keys={len(missing)} extra_keys={len(extra)}")
        if missing:
            print("Missing keys sample:")
            for key in sorted(missing)[:5]:
                print(f"  {key}")
        if extra:
            print("Extra keys sample:")
            for key in sorted(extra)[:5]:
                print(f"  {key}")
        raise AssertionError(
            f"Row key mismatch: missing={len(missing)} extra={len(extra)} "
            f"(expected {len(expected_index)} keys, got {len(actual_index)})"
        )

    for key, expected_row in expected_index.items():
        actual_row = actual_index[key]
        assert_row_matches(actual_row, expected_row, numeric_columns, int_columns)


def validate_columns(model_name, required_columns):
    conn, db_type = get_db_connection()
    try:
        schema = get_table_schema(conn, db_type, model_name)
        if db_type == 'snowflake':
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(%s)
                  AND lower(table_name) = lower(%s)
            """, [schema, model_name])
        else:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(?)
                  AND lower(table_name) = lower(?)
            """, [schema, model_name])
        col_names = {c[0].lower() for c in cols}
        missing = {c.lower() for c in required_columns} - col_names
        assert not missing, f"Missing columns in {model_name}: {missing}"
        print(f"All required columns present for {model_name}")
    finally:
        conn.close()


def load_manifest():
    project_dir = get_dbt_project_dir()
    manifest_path = Path(project_dir) / "target" / "manifest.json"
    assert manifest_path.exists(), f"manifest.json not found at {manifest_path} after dbt run"
    return json.loads(manifest_path.read_text())


def find_model_node(manifest, model_name):
    for node_id, node in manifest.get("nodes", {}).items():
        if node.get("resource_type") == "model" and node.get("name") == model_name:
            return node_id, node
    raise AssertionError(f"Model not found in manifest: {model_name}")


def _round_for_counter(value, ndigits=6):
    """Round floats/Decimals for stable counter comparisons across runs."""
    if value is None:
        return None
    if isinstance(value, (float, Decimal)):
        return round(float(value), ndigits)
    return value


def rows_to_counter(rows, columns):
    return Counter(
        tuple(_round_for_counter(row.get(col)) for col in columns)
        for row in rows
    )


def dependency_model_names(manifest, node):
    dependencies = node.get("depends_on", {}).get("nodes", [])
    model_nodes = manifest.get("nodes", {})
    names = set()
    for node_id in dependencies:
        dep_node = model_nodes.get(node_id)
        if not dep_node:
            continue
        if dep_node.get("resource_type") == "model":
            names.add(dep_node.get("name"))
    return names


def safe_divide(numer, denom):
    if is_null(numer) or is_null(denom):
        return None
    if abs(float(denom)) < 1e-12:
        return None
    return float(numer) / float(denom)


def safe_multiply(left, right):
    if is_null(left) or is_null(right):
        return None
    return float(left) * float(right)


def group_rows_by_keys(rows, keys):
    grouped = defaultdict(list)
    for row in rows:
        key = tuple(row.get(k) for k in keys)
        grouped[key].append(row)
    return grouped


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module", params=MODEL_NAMES)
def model_name(request):
    return request.param


@pytest.fixture(scope="module")
def model_spec(model_name):
    return MODEL_SPECS[model_name]


@pytest.fixture(scope="module")
def output_rows(dbt_run, model_name, model_spec):
    return fetch_model_rows(
        model_name,
        model_spec["numeric_columns"],
        model_spec["int_columns"],
    )


@pytest.fixture(scope="module")
def expected_rows(model_spec):
    return load_expected_rows(
        model_spec["expected_json"],
        model_spec["numeric_columns"],
        model_spec["int_columns"],
    )


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_columns_exist(self, dbt_run, model_name, model_spec):
        """Validate required columns exist."""
        print("\n" + "=" * 50)
        print("PHASE 1: Structure and Basic Validation")
        print("=" * 50)
        validate_columns(model_name, model_spec["required_columns"])

    def test_relation_exists(self, dbt_run, model_name):
        """Validate the model is a view or table."""
        conn, db_type = get_db_connection()
        try:
            relation_type = get_relation_type(conn, db_type, model_name)
            relation_upper = relation_type.upper()
            assert relation_upper in {"VIEW", "BASE TABLE"}, (
                f"Unexpected relation type for {model_name}: {relation_type}"
            )
        finally:
            conn.close()

    def test_non_empty(self, output_rows, model_name):
        """Validate the model output rows."""
        assert output_rows, f"{model_name} returned zero rows"
        print(f"{model_name} rows: {len(output_rows)}")


class TestPhase2Data:
    """Phase 2: Validate data accuracy and metric calculations."""

    def test_output_matches_expected(self, output_rows, expected_rows, model_spec, model_name):
        """Verify all output rows match expected rows by key columns and values."""
        assert_rows_match(
            output_rows,
            expected_rows,
            key_columns=model_spec["key_columns"],
            numeric_columns=model_spec["numeric_columns"],
            int_columns=model_spec["int_columns"],
        )
        print(f"{model_name} matched expected results")

    def test_ratio_metrics(self, output_rows):
        """Validate computed ratio metrics (CTR, conversion rate, ROAS, etc.) are internally consistent."""
        for row in output_rows:
            assert_numeric_close(
                row["ctr"],
                safe_divide(row["clicks"], row["impressions"]),
                **NUMERIC_TOLERANCES.get("ctr", {}),
            )
            assert_numeric_close(
                row["conversion_rate"],
                safe_divide(row["conversions"], row["clicks"]),
                **NUMERIC_TOLERANCES.get("conversion_rate", {}),
            )
            assert_numeric_close(
                row["roas"],
                safe_divide(row["revenue_attributed"], row["spend_amount"]),
                **NUMERIC_TOLERANCES.get("roas", {}),
            )
            assert_numeric_close(
                row["order_conversion_rate"],
                safe_divide(row["order_count"], row["conversions"]),
                **NUMERIC_TOLERANCES.get("order_conversion_rate", {}),
            )
            assert_numeric_close(
                row["new_customer_share"],
                safe_divide(row["new_customers"], row["total_new_customers"]),
                **NUMERIC_TOLERANCES.get("new_customer_share", {}),
            )
            assert_numeric_close(
                row["blended_cac"],
                safe_divide(row["spend_amount"], row["total_new_customers"]),
                **NUMERIC_TOLERANCES.get("blended_cac", {}),
            )

            numerator = safe_multiply(
                row["ltv_90d_profit_per_customer"], row["new_customers"]
            )
            denominator = safe_multiply(row["spend_amount"], row["new_customer_share"])
            assert_numeric_close(
                row["payback_90d_profit_ratio"],
                safe_divide(numerator, denominator),
                **NUMERIC_TOLERANCES.get("payback_90d_profit_ratio", {}),
            )

            for ratio_col in ("ctr", "conversion_rate", "new_customer_share"):
                value = row[ratio_col]
                if not is_null(value):
                    assert 0.0 - EPSILON <= value <= 1.0 + EPSILON, (
                        f"{ratio_col} out of range: {value}"
                    )

            if not is_null(row["new_customers"]):
                assert row["segment_name"] is not None, "segment_name should be populated"
                assert row["tier_name"] is not None, "tier_name should be populated"

            if is_null(row["new_customers"]) or row["new_customers"] == 0:
                assert is_null(row["ltv_90d_revenue_per_customer"])
                assert is_null(row["ltv_90d_profit_per_customer"])

    def test_new_customer_mix(self, output_rows):
        """Verify new_customer shares sum to 1.0 and are consistent within each month-channel group."""
        grouped = group_rows_by_keys(output_rows, ["month_start", "channel_key"])
        for _, rows in grouped.items():
            total_new_customers = rows[0].get("total_new_customers")
            if is_null(total_new_customers):
                for row in rows:
                    assert is_null(row["new_customers"])
                    assert is_null(row["new_customer_share"])
                continue

            for row in rows:
                assert_numeric_close(
                    row["total_new_customers"],
                    total_new_customers,
                )

            total_value = float(total_new_customers)
            if abs(total_value) < 1e-12:
                for row in rows:
                    assert is_null(row["new_customer_share"])
                continue

            sum_new_customers = sum(
                row["new_customers"]
                for row in rows
                if not is_null(row["new_customers"])
            )
            assert_numeric_close(sum_new_customers, total_new_customers)

            sum_share = sum(
                row["new_customer_share"]
                for row in rows
                if not is_null(row["new_customer_share"])
            )
            assert_numeric_close(sum_share, 1.0, rel_tol=1e-4, abs_tol=1e-4)


class TestPhase3DbtArtifacts:
    """Phase 3: Validate dbt artifacts and model metadata."""

    def test_model_in_manifest(self, dbt_run, model_name):
        """Verify the model appears in the dbt manifest.json after a successful run."""
        manifest = load_manifest()
        find_model_node(manifest, model_name)

    def test_no_sources_used(self, dbt_run, model_name):
        """Ensure the model does not directly depend on any dbt source nodes."""
        manifest = load_manifest()
        _, node = find_model_node(manifest, model_name)
        dependencies = set(node.get("depends_on", {}).get("nodes", []))
        source_nodes = set(manifest.get("sources", {}).keys())
        used_sources = dependencies.intersection(source_nodes)
        assert not used_sources, f"{model_name} depends on sources: {used_sources}"

    def test_dependencies_are_allowed(self, dbt_run, model_name):
        """Verify the model only references models in the allowed dependency set."""
        manifest = load_manifest()
        _, node = find_model_node(manifest, model_name)
        dep_names = dependency_model_names(manifest, node)
        allowed = MODEL_SPECS[model_name]["allowed_refs"]
        extra = dep_names - allowed
        assert not extra, f"Unexpected refs in {model_name} dependencies: {extra}"


class TestPhase4Idempotency:
    """Phase 4: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, output_rows):
        """Test that re-running dbt produces the same results."""
        print("\n" + "=" * 50)
        print("PHASE 4: Idempotency Test")
        print("=" * 50)

        rows_before = list(output_rows)
        run_dbt_pipeline()
        rows_after = fetch_model_rows(
            MODEL_NAME,
            MODEL_SPECS[MODEL_NAME]["numeric_columns"],
            MODEL_SPECS[MODEL_NAME]["int_columns"],
        )

        required_columns = MODEL_SPECS[MODEL_NAME]["required_columns"]
        before_counter = rows_to_counter(rows_before, required_columns)
        after_counter = rows_to_counter(rows_after, required_columns)
        assert before_counter == after_counter, f"{MODEL_NAME} changed after re-run"

        print("Idempotency verified for ROI payback model")
