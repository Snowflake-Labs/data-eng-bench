"""
Test verifier for cart recovery prioritization models.
Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate data accuracy, sampled rows, and business logic
  Phase 3: Validate dbt artifacts and dependencies
  Phase 4: Test idempotency (re-run produces same results)
"""
import json
import math
import os
import subprocess
from collections import Counter
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import pytest


# ============ CONSTANTS ============

MODEL_NAMES = [
    "int_cart_recovery__cart_base",
    "int_cart_recovery__session_signals",
    "int_cart_recovery__inventory_risk",
    "int_cart_recovery__customer_context",
    "fct_cart_recovery_priority",
]

EXPECTED_DIR = Path(__file__).resolve().parent / "expected"
COUNTS_PATH = EXPECTED_DIR / "count_stats.json"
ID_SAMPLING_PATH = EXPECTED_DIR / "id_sampling.json"

DATE_ONLY_COLUMNS = set()

MODEL_SPECS = {
    "int_cart_recovery__cart_base": {
        "expected_json": EXPECTED_DIR / "sample_int_cart_recovery__cart_base.json",
        "sample_only": True,
        "dynamic_columns": {"hours_since_last_activity", "cart_age_hours"},
    },
    "int_cart_recovery__session_signals": {
        "expected_json": EXPECTED_DIR / "sample_int_cart_recovery__session_signals.json",
        "sample_only": True,
        "dynamic_columns": set(),
    },
    "int_cart_recovery__inventory_risk": {
        "expected_json": EXPECTED_DIR / "sample_int_cart_recovery__inventory_risk.json",
        "sample_only": True,
        "dynamic_columns": set(),
    },
    "int_cart_recovery__customer_context": {
        "expected_json": EXPECTED_DIR / "sample_int_cart_recovery__customer_context.json",
        "sample_only": True,
        "dynamic_columns": set(),
    },
    "fct_cart_recovery_priority": {
        "expected_json": EXPECTED_DIR / "sample_fct_cart_recovery_priority.json",
        "sample_only": True,
        "dynamic_columns": {"hours_since_last_activity", "cart_age_hours", "scored_at"},
    },
}

ALLOWED_SOURCE_MODELS = {
    "stg_shopping_carts",
    "stg_shopping_cart_items",
    "stg_abandoned_carts_stg",
    "stg_web_sessions",
    "stg_web_events",
    "stg_inventory_levels",
    "stg_customer__customers",
    "stg_customer__customer_tiers",
    "stg_consent_preferences",
    "stg_orders__orders",
}

ALLOWED_DEPENDENCY_PREFIXES = {"int_cart_recovery__"}
ALLOWED_DEPENDENCIES = set(MODEL_NAMES) | ALLOWED_SOURCE_MODELS

NUMERIC_TOLERANCE = {"rel_tol": 1e-6, "abs_tol": 1e-6}


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


def execute_query_with_columns(conn, db_type, query, params=None):
    """Execute a query and return (rows, col_names)"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        if params:
            cursor.execute(query, params)
        else:
            cursor.execute(query)
        col_names = [desc[0].lower() for desc in cursor.description]
        rows = cursor.fetchall()
        return rows, col_names
    else:
        if params:
            cur = conn.execute(query, params)
        else:
            cur = conn.execute(query)
        col_names = [desc[0].lower() for desc in cur.description]
        rows = cur.fetchall()
        return rows, col_names


# ============ HELPERS ============

def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


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
    """Run dbt for the cart recovery models."""
    run_cmd("dbt deps")
    selectors = " ".join(MODEL_NAMES)
    result = run_cmd(f"dbt run -s {selectors}")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_connection():
    """Get database connection (returns conn, db_type tuple)."""
    return get_db_connection()


def get_table_identifier(conn, db_type, table_name):
    query = """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE lower(table_name) = lower(%s)
        ORDER BY table_schema
        LIMIT 1
    """ if db_type == 'snowflake' else """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE lower(table_name) = lower(?)
        ORDER BY table_schema
        LIMIT 1
    """
    rows = execute_query(conn, db_type, query, [table_name])
    if not rows:
        raise AssertionError(f"Table or view not found: {table_name}")
    return rows[0][0], rows[0][1]


def get_column_identifier(conn, db_type, table_name, column_name):
    schema, actual_table = get_table_identifier(conn, db_type, table_name)
    query = """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_schema) = lower(%s)
          AND lower(table_name) = lower(%s)
          AND lower(column_name) = lower(%s)
        ORDER BY ordinal_position
        LIMIT 1
    """ if db_type == 'snowflake' else """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_schema) = lower(?)
          AND lower(table_name) = lower(?)
          AND lower(column_name) = lower(?)
        ORDER BY ordinal_position
        LIMIT 1
    """
    rows = execute_query(conn, db_type, query, [schema, actual_table, column_name])
    if not rows:
        raise AssertionError(f"Column not found: {table_name}.{column_name}")
    return rows[0][0]


def qualified_table(conn, db_type, table_name):
    schema, actual_name = get_table_identifier(conn, db_type, table_name)
    return f'"{schema}"."{actual_name}"'


def get_table_schema(conn, db_type, table_name):
    schema, _ = get_table_identifier(conn, db_type, table_name)
    return schema


def get_relation_type(conn, db_type, table_name):
    query = """
        SELECT table_type
        FROM information_schema.tables
        WHERE lower(table_name) = lower(%s)
        ORDER BY table_schema
        LIMIT 1
    """ if db_type == 'snowflake' else """
        SELECT table_type
        FROM information_schema.tables
        WHERE lower(table_name) = lower(?)
        ORDER BY table_schema
        LIMIT 1
    """
    rows = execute_query(conn, db_type, query, [table_name])
    if not rows:
        raise AssertionError(f"Table or view not found: {table_name}")
    return rows[0][0]


def fetch_row_count(table_name):
    conn, db_type = get_connection()
    try:
        qualified = qualified_table(conn, db_type, table_name)
        rows = execute_query(conn, db_type, f"SELECT COUNT(*) FROM {qualified}")
        return rows[0][0]
    finally:
        conn.close()


def is_null(value):
    if value is None:
        return True
    return isinstance(value, float) and math.isnan(value)


def to_float(value):
    if value is None or is_null(value):
        return None
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, bool):
        return float(int(value))
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise AssertionError(f"Expected numeric value, got {value!r}") from exc


def to_int(value):
    if value is None or is_null(value):
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, Decimal):
        return int(value)
    try:
        return int(float(value))
    except (TypeError, ValueError) as exc:
        raise AssertionError(f"Expected integer value, got {value!r}") from exc


def parse_bool(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        value_lower = value.strip().lower()
        if value_lower in {"true", "t", "1"}:
            return True
        if value_lower in {"false", "f", "0"}:
            return False
    raise AssertionError(f"Unexpected boolean value: {value!r}")


def parse_timestamp(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        return value
    if isinstance(value, date):
        return datetime.combine(value, datetime.min.time())
    if isinstance(value, str):
        if len(value) == 10:
            return datetime.strptime(value, "%Y-%m-%d")
        try:
            return datetime.fromisoformat(value)
        except ValueError as exc:
            raise AssertionError(f"Invalid timestamp value: {value!r}") from exc
    raise AssertionError(f"Unsupported timestamp type: {type(value)}")


def normalize_value_for_signature(value, column_name=None):
    if value is None:
        return None
    if column_name in DATE_ONLY_COLUMNS:
        parsed = parse_timestamp(value)
        return None if parsed is None else parsed.strftime("%Y-%m-%d")
    if isinstance(value, Decimal):
        value = float(value)
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    if isinstance(value, date):
        return value.strftime("%Y-%m-%d")
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return round(float(value), 6)
    # Handle Snowflake VARCHAR booleans
    if isinstance(value, str) and value.lower() in ('true', 'false'):
        return value.lower() == 'true'
    return str(value)


def row_signature(row, columns):
    return tuple(normalize_value_for_signature(row.get(col), col) for col in columns)


def load_expected_rows(path):
    raw = json.loads(Path(path).read_text())
    if isinstance(raw, dict):
        if len(raw) != 1:
            raise AssertionError(f"Expected one top-level key in {path}")
        rows = next(iter(raw.values()))
    else:
        rows = raw
    return [{k.lower(): v for k, v in row.items()} for row in rows]


def iter_rows(conn, db_type, table_name, columns=None, chunk_size=10000):
    qualified = qualified_table(conn, db_type, table_name)
    if columns:
        actual_columns = [get_column_identifier(conn, db_type, table_name, col) for col in columns]
        column_clause = ", ".join(f'"{col}"' for col in actual_columns)
    else:
        column_clause = "*"
    query = f"SELECT {column_clause} FROM {qualified}"
    rows, col_names = execute_query_with_columns(conn, db_type, query)
    for row in rows:
        yield dict(zip(col_names, row))


def assert_numeric_close(actual, expected, rel_tol=1e-6, abs_tol=1e-6):
    if is_null(expected):
        assert is_null(actual), f"Expected null, got {actual}"
        return
    assert not is_null(actual), f"Expected value, got null"
    assert math.isclose(float(actual), float(expected), rel_tol=rel_tol, abs_tol=abs_tol), (
        f"Numeric mismatch: {actual} != {expected}"
    )


def fetch_rows_for_ids(table_name, key_column, ids):
    if not ids:
        raise AssertionError(f"No ids provided for {table_name}")
    ids = list(dict.fromkeys(ids))
    conn, db_type = get_connection()
    try:
        schema, actual_table = get_table_identifier(conn, db_type, table_name)
        key_col = get_column_identifier(conn, db_type, table_name, key_column)
        if db_type == 'snowflake':
            placeholders = ", ".join(["%s"] * len(ids))
        else:
            placeholders = ", ".join(["?"] * len(ids))
        query = (
            f'SELECT * FROM "{schema}"."{actual_table}" '
            f'WHERE "{key_col}" IN ({placeholders})'
        )
        rows, col_names = execute_query_with_columns(conn, db_type, query, ids)
        return [dict(zip(col_names, row)) for row in rows]
    finally:
        conn.close()


def assert_rows_equal_filtered(table_name, key_column, expected_rows, ids, exclude_columns=None):
    if not expected_rows:
        raise AssertionError(f"No expected rows provided for {table_name}")
    exclude_columns = {col.lower() for col in (exclude_columns or set())}
    columns = [col for col in expected_rows[0].keys() if col not in exclude_columns]
    expected_counts = Counter(row_signature(row, columns) for row in expected_rows)
    actual_rows = fetch_rows_for_ids(table_name, key_column, ids)
    actual_counts = Counter(row_signature(row, columns) for row in actual_rows)

    if actual_counts != expected_counts:
        missing = sum((expected_counts - actual_counts).values())
        extra = sum((actual_counts - expected_counts).values())
        raise AssertionError(
            f"Row mismatch for {table_name}: missing={missing} extra={extra}"
        )


def assert_rows_equal_exact(table_name, expected_rows, exclude_columns=None):
    if not expected_rows:
        raise AssertionError(f"No expected rows provided for {table_name}")
    exclude_columns = {col.lower() for col in (exclude_columns or set())}
    columns = [col for col in expected_rows[0].keys() if col not in exclude_columns]
    expected_counts = Counter(row_signature(row, columns) for row in expected_rows)

    conn, db_type = get_connection()
    try:
        actual_counts = Counter(
            row_signature(row, columns)
            for row in iter_rows(conn, db_type, table_name, columns=columns)
        )
    finally:
        conn.close()

    if actual_counts != expected_counts:
        missing = sum((expected_counts - actual_counts).values())
        extra = sum((actual_counts - expected_counts).values())
        raise AssertionError(
            f"Row mismatch for {table_name}: missing={missing} extra={extra}"
        )


def validate_columns(model_name, required_columns):
    conn, db_type = get_connection()
    try:
        schema = get_table_schema(conn, db_type, model_name)
        if db_type == 'snowflake':
            query = """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(%s)
                  AND lower(table_name) = lower(%s)
            """
        else:
            query = """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower(?)
                  AND lower(table_name) = lower(?)
            """
        rows = execute_query(conn, db_type, query, [schema, model_name])
        col_names = {c[0].lower() for c in rows}
        missing = {c.lower() for c in required_columns} - col_names
        assert not missing, f"Missing columns in {model_name}: {missing}"
        print(f"All required columns present for {model_name}")
    finally:
        conn.close()


def load_manifest():
    dbt_project_dir = get_dbt_project_dir()
    manifest_path = Path(dbt_project_dir) / "target" / "manifest.json"
    assert manifest_path.exists(), "manifest.json not found after dbt run"
    return json.loads(manifest_path.read_text())


def find_model_node(manifest, model_name):
    for node_id, node in manifest.get("nodes", {}).items():
        if node.get("resource_type") == "model" and node.get("name") == model_name:
            return node_id, node
    raise AssertionError(f"Model not found in manifest: {model_name}")


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


def load_expected_counts():
    raw = json.loads(COUNTS_PATH.read_text())
    rows = raw.get("count_stats", [])
    return {row["model_name"]: row["counts"] for row in rows}


def load_id_sampling():
    data = json.loads(ID_SAMPLING_PATH.read_text())
    samples = data.get("samples", {})
    mapping = {}
    for sample in samples.values():
        table = sample.get("table")
        key_name = sample.get("key_name")
        values = [str(value) for value in sample.get("values", [])]
        if table:
            mapping[table] = {"key_name": key_name, "values": values}
    return mapping


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
def expected_rows(model_spec):
    return load_expected_rows(model_spec["expected_json"])


@pytest.fixture(scope="module")
def expected_counts():
    return load_expected_counts()


@pytest.fixture(scope="module")
def id_sampling():
    return load_id_sampling()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_columns_exist(self, dbt_run, model_name, expected_rows):
        """Validate required columns exist."""
        print("\n" + "=" * 50)
        print("PHASE 1: Structure and Basic Validation")
        print("=" * 50)
        required_columns = list(expected_rows[0].keys())
        validate_columns(model_name, required_columns)

    def test_relation_exists(self, dbt_run, model_name):
        """Validate the model is a view or table."""
        conn, db_type = get_connection()
        try:
            relation_type = get_relation_type(conn, db_type, model_name)
            relation_upper = relation_type.upper()
            assert relation_upper in {"VIEW", "BASE TABLE"}, (
                f"Unexpected relation type for {model_name}: {relation_type}"
            )
        finally:
            conn.close()

    def test_non_empty(self, dbt_run, model_name):
        count = fetch_row_count(model_name)
        assert count > 0, f"{model_name} returned zero rows"
        print(f"{model_name} rows: {count}")


class TestPhase2Data:
    """Phase 2: Validate data accuracy and business logic."""

    def test_row_counts_match_expected(self, dbt_run, model_name, expected_counts):
        expected = expected_counts.get(model_name)
        assert expected is not None, f"Missing expected count for {model_name}"
        actual = fetch_row_count(model_name)
        assert actual == expected, f"{model_name} count mismatch: {actual} != {expected}"

    def test_expected_rows_match(self, dbt_run, model_name, model_spec, expected_rows, id_sampling):
        exclude_columns = model_spec.get("dynamic_columns", set())
        if model_spec["sample_only"]:
            sample_spec = id_sampling.get(model_name)
            assert sample_spec, f"No sample ids configured for {model_name}"
            key_name = sample_spec["key_name"]
            ids = sample_spec["values"]
            assert key_name, f"Missing key_name for {model_name} in sampling config"
            assert ids, f"No sample ids configured for {model_name}"
            assert_rows_equal_filtered(model_name, key_name, expected_rows, ids, exclude_columns)
        else:
            assert_rows_equal_exact(model_name, expected_rows, exclude_columns)

    def test_cart_base_flags_and_values(self, dbt_run, id_sampling):
        sample_spec = id_sampling.get("int_cart_recovery__cart_base")
        assert sample_spec, "Missing sampling for int_cart_recovery__cart_base"
        rows = fetch_rows_for_ids(
            "int_cart_recovery__cart_base",
            sample_spec["key_name"],
            sample_spec["values"],
        )
        for row in rows:
            cart_status = (row.get("cart_status") or "").upper()
            abandoned_status = (row.get("abandoned_status") or "").upper()
            expected_is_converted = bool(
                row.get("order_id") is not None
                or row.get("converted_at") is not None
                or cart_status == "CONVERTED"
            )
            assert parse_bool(row.get("is_converted")) == expected_is_converted

            expected_is_abandoned = (
                cart_status == "ABANDONED"
                or abandoned_status == "ABANDONED"
                or (not expected_is_converted and cart_status in {"CANCELLED", "EXPIRED"})
            )
            assert parse_bool(row.get("is_abandoned")) == expected_is_abandoned

            items_total = to_float(row.get("items_total"))
            subtotal = to_float(row.get("cart_subtotal_reported"))
            expected_merch_value = items_total if items_total is not None else (subtotal or 0)
            assert_numeric_close(
                to_float(row.get("cart_merch_value")),
                expected_merch_value,
                **NUMERIC_TOLERANCE,
            )

            created_at = parse_timestamp(row.get("created_at"))
            updated_at = parse_timestamp(row.get("updated_at")) or created_at
            last_item_updated_at = parse_timestamp(row.get("last_item_updated_at"))
            last_item_added_at = parse_timestamp(row.get("last_item_added_at"))
            converted_at = parse_timestamp(row.get("converted_at")) or created_at

            candidate_updated = updated_at or created_at
            candidate_items = last_item_updated_at or last_item_added_at or created_at
            candidate_converted = converted_at or created_at
            expected_last_activity = max(candidate_updated, candidate_items, candidate_converted)
            assert parse_timestamp(row.get("last_activity_at")) == expected_last_activity

            hours_since = to_float(row.get("hours_since_last_activity"))
            cart_age = to_float(row.get("cart_age_hours"))
            if hours_since is not None and cart_age is not None:
                assert cart_age >= hours_since

    def test_session_signals_metrics(self, dbt_run, id_sampling):
        sample_spec = id_sampling.get("int_cart_recovery__session_signals")
        assert sample_spec, "Missing sampling for int_cart_recovery__session_signals"
        rows = fetch_rows_for_ids(
            "int_cart_recovery__session_signals",
            sample_spec["key_name"],
            sample_spec["values"],
        )
        for row in rows:
            event_count = to_int(row.get("event_count")) or 0
            checkout_event_count = to_int(row.get("checkout_event_count")) or 0
            payment_error_count = to_int(row.get("payment_error_count")) or 0

            expected_depth = 2 if payment_error_count > 0 else 1 if checkout_event_count > 0 else 0
            assert to_int(row.get("checkout_depth_score")) == expected_depth

            add_to_cart_count = to_int(row.get("add_to_cart_count")) or 0
            remove_from_cart_count = to_int(row.get("remove_from_cart_count")) or 0
            expected_cart_add_net = add_to_cart_count - remove_from_cart_count
            assert to_int(row.get("cart_add_net")) == expected_cart_add_net

            ratio = row.get("checkout_event_ratio")
            if event_count > 0:
                expected_ratio = checkout_event_count / event_count
                assert_numeric_close(ratio, expected_ratio, **NUMERIC_TOLERANCE)
            else:
                assert ratio is None or is_null(ratio)

            first_event = parse_timestamp(row.get("first_event_at"))
            last_event = parse_timestamp(row.get("last_event_at"))
            if first_event and last_event:
                assert first_event <= last_event

    def test_inventory_risk_logic(self, dbt_run, id_sampling):
        sample_spec = id_sampling.get("int_cart_recovery__inventory_risk")
        assert sample_spec, "Missing sampling for int_cart_recovery__inventory_risk"
        rows = fetch_rows_for_ids(
            "int_cart_recovery__inventory_risk",
            sample_spec["key_name"],
            sample_spec["values"],
        )
        for row in rows:
            line_out_of_stock = to_int(row.get("line_out_of_stock")) or 0
            line_low_stock_status = to_int(row.get("line_low_stock_status")) or 0
            expected_flag = line_out_of_stock > 0 or line_low_stock_status > 0
            assert parse_bool(row.get("inventory_risk_flag")) == expected_flag

            expected_level = (
                "OUT_OF_STOCK"
                if line_out_of_stock > 0
                else "LOW_STOCK"
                if line_low_stock_status > 0
                else "OK"
            )
            assert row.get("inventory_risk_level") == expected_level

    def test_customer_context_consents(self, dbt_run, id_sampling):
        sample_spec = id_sampling.get("int_cart_recovery__customer_context")
        assert sample_spec, "Missing sampling for int_cart_recovery__customer_context"
        rows = fetch_rows_for_ids(
            "int_cart_recovery__customer_context",
            sample_spec["key_name"],
            sample_spec["values"],
        )
        for row in rows:
            for field in ("email_consent", "sms_consent", "push_consent", "personalization_consent"):
                value = to_int(row.get(field))
                assert value in {0, 1}, f"Unexpected consent value {value} for {field}"

            lifetime_value = to_float(row.get("total_lifetime_value"))
            if lifetime_value is not None:
                assert lifetime_value >= 0

    def test_priority_model_logic(self, dbt_run, id_sampling):
        sample_spec = id_sampling.get("fct_cart_recovery_priority")
        assert sample_spec, "Missing sampling for fct_cart_recovery_priority"
        rows = fetch_rows_for_ids(
            "fct_cart_recovery_priority",
            sample_spec["key_name"],
            sample_spec["values"],
        )
        for row in rows:
            priority_score = to_int(row.get("priority_score"))
            assert priority_score is not None
            expected_tier = "P0" if priority_score >= 55 else "P1" if priority_score >= 40 else "P2"
            assert row.get("priority_tier") == expected_tier

            expected_window = 2 if priority_score >= 55 else 24 if priority_score >= 40 else 72
            assert to_int(row.get("recovery_window_hours")) == expected_window

            assert row.get("recommended_channel") in {"EMAIL", "SMS", "PUSH", "SUPPRESS"}

            last_activity = parse_timestamp(row.get("last_activity_at"))
            recovery_start = parse_timestamp(row.get("recovery_window_start"))
            if last_activity and recovery_start:
                assert abs((recovery_start - last_activity).total_seconds()) < 1

            recovery_end = parse_timestamp(row.get("recovery_window_end"))
            if last_activity and recovery_end:
                expected_end = last_activity + timedelta(hours=expected_window)
                assert abs((recovery_end - expected_end).total_seconds()) < 1

            payment_error_count = to_int(row.get("payment_error_count")) or 0
            inventory_risk_level = (row.get("inventory_risk_level") or "").upper()
            inventory_risk_flag = inventory_risk_level in {"LOW_STOCK", "OUT_OF_STOCK"}
            expected_incentive = (
                (priority_score >= 55 and (payment_error_count > 0 or inventory_risk_flag))
                or (priority_score >= 40 and payment_error_count > 0)
            )
            assert parse_bool(row.get("incentive_flag")) == expected_incentive

            recovered_order_id = row.get("recovered_order_id")
            if recovered_order_id is not None:
                assert parse_bool(row.get("is_recovered")) is True


class TestPhase3DbtArtifacts:
    """Phase 3: Validate dbt artifacts and model metadata."""

    def test_model_in_manifest(self, dbt_run, model_name):
        manifest = load_manifest()
        find_model_node(manifest, model_name)

    def test_no_sources_used(self, dbt_run, model_name):
        manifest = load_manifest()
        _, node = find_model_node(manifest, model_name)
        dependencies = set(node.get("depends_on", {}).get("nodes", []))
        source_nodes = set(manifest.get("sources", {}).keys())
        used_sources = dependencies.intersection(source_nodes)
        assert not used_sources, f"{model_name} depends on sources: {used_sources}"

    def test_dependencies_are_allowed(self, dbt_run, model_name):
        manifest = load_manifest()
        _, node = find_model_node(manifest, model_name)
        dep_names = dependency_model_names(manifest, node)
        extra = {
            name
            for name in dep_names
            if name not in ALLOWED_DEPENDENCIES
            and not any(name.startswith(prefix) for prefix in ALLOWED_DEPENDENCY_PREFIXES)
        }
        assert not extra, f"Unexpected refs in {model_name} dependencies: {extra}"


class TestPhase4Idempotency:
    """Phase 4: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, dbt_run):
        print("\n" + "=" * 50)
        print("PHASE 4: Idempotency Test")
        print("=" * 50)

        counts_before = {model: fetch_row_count(model) for model in MODEL_NAMES}
        run_dbt_pipeline()
        counts_after = {model: fetch_row_count(model) for model in MODEL_NAMES}

        assert counts_after == counts_before
        print("Idempotency verified for cart recovery models")
