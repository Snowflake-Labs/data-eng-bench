"""
Test verifier for review moderation trust-risk models.
Multi-phase testing validates structure, data accuracy, dbt artifacts,
and idempotency for agentic dbt runs.
"""
import json
import math
import os
import subprocess
from collections import Counter
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
        private_key_pem, password=passphrase_bytes, backend=default_backend()
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
    """Execute a query and return results"""
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


def get_db_type():
    return os.environ.get('DB_TYPE', 'duckdb').lower()


# ============ CONSTANTS ============

MODEL_NAMES = [
    "int_reviews__enriched",
    "fct_review_moderation_risk",
    "rpt_review_moderation_kpis",
]

SAMPLED_MODELS = [
    "int_reviews__enriched",
    "fct_review_moderation_risk",
]

FULL_DUMP_MODELS = [
    "rpt_review_moderation_kpis",
]

EXPECTED_DIR = Path(__file__).resolve().parent / "expected"


def _sf_prefix():
    """Return 'sf_' prefix when running on Snowflake, '' otherwise."""
    return "sf_" if get_db_type() == 'snowflake' else ""


def get_model_specs():
    """Return expected file paths for sampled models, DB-type aware."""
    pfx = _sf_prefix()
    return {
        "int_reviews__enriched": {
            "expected_rows": EXPECTED_DIR / f"{pfx}int_reviews__enriched_rows.json",
            "expected_ids": EXPECTED_DIR / f"{pfx}int_reviews__enriched_ids.json",
        },
        "fct_review_moderation_risk": {
            "expected_rows": EXPECTED_DIR / f"{pfx}fct_review_moderation_risk_rows.json",
            "expected_ids": EXPECTED_DIR / f"{pfx}fct_review_moderation_risk_ids.json",
        },
    }


def get_full_dump_specs():
    """Return expected file paths for full-dump models, DB-type aware."""
    pfx = _sf_prefix()
    return {
        "rpt_review_moderation_kpis": {
            "expected_rows": EXPECTED_DIR / f"{pfx}rpt_review_moderation_kpis.json",
        }
    }

DATE_ONLY_COLUMNS = {
    "review_date",
    "first_order_date",
    "last_order_date",
    "product_last_review_date",
}

ALLOWED_SOURCE_MODELS = {
    "stg_product__product_reviews",
    "stg_orders__orders",
    "stg_orders__order_lines",
    "stg_orders__order_fraud_scores",
    "stg_orders__returns",
    "stg_orders__return_lines",
    "stg_coupon_usage",
    "stg_customer__customers",
    "stg_product_ratings_summary",
    "stg_events",
}

ALLOWED_DEPENDENCIES = set(MODEL_NAMES) | ALLOWED_SOURCE_MODELS


# ============ HELPERS ============

def run_cmd(cmd, cwd=None):
    """Run a shell command and capture output for debugging."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt for the review moderation trust-risk models."""
    run_cmd("dbt deps")
    selectors = " ".join(MODEL_NAMES)
    result = run_cmd(f"dbt run -s {selectors} --profiles-dir ./")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"
    result = run_cmd(f"dbt test -s {selectors} --profiles-dir ./")
    assert result.returncode == 0, f"dbt test failed: {result.stderr}"


def get_connection():
    """Open a database connection using the dual-backend infrastructure."""
    return get_db_connection()


def _param_placeholder():
    """Return the correct parameter placeholder for the current DB type."""
    if get_db_type() == 'snowflake':
        return '%s'
    return '?'


def get_table_identifier(conn, db_type, table_name):
    """Resolve table schema and name with case-insensitive lookup."""
    ph = _param_placeholder()
    query = f"""
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE lower(table_name) = lower({ph})
        ORDER BY table_schema
        LIMIT 1
    """
    result = execute_query(conn, db_type, query, [table_name])
    if not result:
        raise AssertionError(f"Table or view not found: {table_name}")
    return result[0][0], result[0][1]


def get_column_identifier(conn, db_type, table_name, column_name):
    """Resolve a column name using case-insensitive lookup."""
    schema, actual_table = get_table_identifier(conn, db_type, table_name)
    ph = _param_placeholder()
    query = f"""
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_schema) = lower({ph})
          AND lower(table_name) = lower({ph})
          AND lower(column_name) = lower({ph})
        ORDER BY ordinal_position
        LIMIT 1
    """
    result = execute_query(conn, db_type, query, [schema, actual_table, column_name])
    if not result:
        raise AssertionError(f"Column not found: {table_name}.{column_name}")
    return result[0][0]


def qualified_table(conn, db_type, table_name):
    """Build a fully qualified table name with schema and quotes."""
    schema, actual_name = get_table_identifier(conn, db_type, table_name)
    return f'"{schema}"."{actual_name}"'


def get_table_schema(conn, db_type, table_name):
    """Return the table schema for a given model name."""
    schema, _ = get_table_identifier(conn, db_type, table_name)
    return schema


def get_relation_type(conn, db_type, table_name):
    """Fetch the relation type from information_schema."""
    ph = _param_placeholder()
    query = f"""
        SELECT table_type
        FROM information_schema.tables
        WHERE lower(table_name) = lower({ph})
        ORDER BY table_schema
        LIMIT 1
    """
    result = execute_query(conn, db_type, query, [table_name])
    if not result:
        raise AssertionError(f"Table or view not found: {table_name}")
    return result[0][0]


def fetch_row_count(table_name):
    """Count total rows in a model relation."""
    conn, db_type = get_connection()
    try:
        q = qualified_table(conn, db_type, table_name)
        return int(execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {q}"))
    finally:
        conn.close()


def parse_datetime_string(value):
    """Parse a string into a datetime when the format is recognizable."""
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value:
        return None
    if len(value) == 10 and value[4] == "-" and value[7] == "-":
        try:
            return datetime.strptime(value, "%Y-%m-%d")
        except ValueError:
            return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def parse_numeric_string(value):
    """Parse numeric-like strings into floats for comparisons."""
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if not stripped or not any(ch.isdigit() for ch in stripped):
        return None
    try:
        numeric = Decimal(stripped)
    except Exception:
        return None
    if numeric.is_nan():
        return None
    return float(numeric)


def normalize_value_for_signature(value, column_name=None):
    """Normalize values into comparable, hashable signatures."""
    if value is None:
        return None
    if isinstance(value, float) and math.isnan(value):
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, Decimal):
        value = float(value)
    if isinstance(value, datetime):
        if column_name in DATE_ONLY_COLUMNS:
            return value.strftime("%Y-%m-%d")
        return value.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    if isinstance(value, date):
        if column_name in DATE_ONLY_COLUMNS:
            return value.strftime("%Y-%m-%d")
        return datetime.combine(value, datetime.min.time()).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    if isinstance(value, str):
        # Handle boolean-like strings from Snowflake (VARCHAR booleans)
        stripped_upper = value.strip().upper()
        if stripped_upper in ('TRUE', 'FALSE'):
            return 1 if stripped_upper == 'TRUE' else 0
        parsed = parse_datetime_string(value)
        if parsed is not None:
            if column_name in DATE_ONLY_COLUMNS:
                return parsed.strftime("%Y-%m-%d")
            return parsed.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        numeric = parse_numeric_string(value)
        if numeric is not None:
            return round(float(numeric), 6)
        return value.strip()
    if isinstance(value, (int, float)):
        return round(float(value), 6)
    return str(value)


def normalize_value_for_comparison(value):
    """Normalize values into stable, comparable scalars."""
    if value is None:
        return None
    if isinstance(value, float) and math.isnan(value):
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    if isinstance(value, date):
        return datetime.combine(value, datetime.min.time()).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    if isinstance(value, str):
        stripped = value.strip()
        parsed = parse_datetime_string(stripped)
        if parsed is not None:
            return parsed.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        numeric = parse_numeric_string(stripped)
        if numeric is not None:
            return float(numeric)
        return stripped
    if isinstance(value, (int, float)):
        return float(value)
    return value


def row_signature(row, columns):
    """Create a tuple signature for a row based on ordered columns."""
    return tuple(normalize_value_for_signature(row.get(col), col) for col in columns)


def load_expected_rows(path):
    """Load sampled expected rows from JSON and normalize keys."""
    raw = json.loads(Path(path).read_text())
    if not isinstance(raw, dict) or "rows" not in raw:
        raise AssertionError(f"Expected rows file format invalid: {path}")
    rows = raw.get("rows", [])
    if not rows:
        raise AssertionError(f"Expected rows missing for {path}")
    normalized = [{k.lower(): v for k, v in row.items()} for row in rows]
    expected_keys = set(normalized[0].keys())
    for row in normalized[1:]:
        if set(row.keys()) != expected_keys:
            raise AssertionError(f"Inconsistent columns in expected data for {path}")
    count = raw.get("count")
    if count is not None and count != len(normalized):
        raise AssertionError(
            f"Expected count mismatch for {path}: {count} != {len(normalized)}"
        )
    return {
        "table": raw.get("table"),
        "count": len(normalized),
        "rows": normalized,
    }


def load_expected_ids(path):
    """Load sampled expected ids from JSON and normalize keys."""
    raw = json.loads(Path(path).read_text())
    if not isinstance(raw, dict) or "ids" not in raw:
        raise AssertionError(f"Expected ids file format invalid: {path}")
    ids = raw.get("ids", [])
    if not ids:
        raise AssertionError(f"Expected ids missing for {path}")
    normalized_ids = [{k.lower(): v for k, v in row.items()} for row in ids]
    id_fields = [field.lower() for field in raw.get("id_fields", [])]
    if not id_fields:
        raise AssertionError(f"Missing id_fields in {path}")
    for row in normalized_ids:
        if set(row.keys()) != set(id_fields):
            raise AssertionError(f"Id row keys do not match id_fields in {path}")
    count = raw.get("count")
    if count is not None and count != len(normalized_ids):
        raise AssertionError(
            f"Expected id count mismatch for {path}: {count} != {len(normalized_ids)}"
        )
    return {
        "table": raw.get("table"),
        "count": len(normalized_ids),
        "id_fields": id_fields,
        "ids": normalized_ids,
    }


def load_expected_full_rows(path):
    """Load full dump rows stored under a single query key."""
    raw = json.loads(Path(path).read_text())
    if not isinstance(raw, dict) or len(raw) != 1:
        raise AssertionError(f"Expected full dump format invalid: {path}")
    query, rows = next(iter(raw.items()))
    if not isinstance(rows, list) or not rows:
        raise AssertionError(f"Expected full dump rows missing for {path}")
    normalized = [{k.lower(): v for k, v in row.items()} for row in rows]
    expected_keys = set(normalized[0].keys())
    for row in normalized[1:]:
        if set(row.keys()) != expected_keys:
            raise AssertionError(f"Inconsistent columns in full dump for {path}")
    return {
        "query": query,
        "count": len(normalized),
        "rows": normalized,
    }


def load_expected_row_counts(path):
    """Load expected row counts for each model from JSON."""
    raw = json.loads(Path(path).read_text())
    if not isinstance(raw, dict) or not raw:
        raise AssertionError(f"Expected row counts format invalid: {path}")
    return {k: int(v) for k, v in raw.items()}


def iter_rows(conn, db_type, table_name, columns=None, chunk_size=10000):
    """Yield rows from a table in chunks as dictionaries."""
    q = qualified_table(conn, db_type, table_name)
    if columns:
        actual_columns = [get_column_identifier(conn, db_type, table_name, col) for col in columns]
        column_clause = ", ".join(f'"{col}"' for col in actual_columns)
    else:
        column_clause = "*"

    if db_type == 'snowflake':
        cursor = conn.cursor()
        cursor.execute(f"SELECT {column_clause} FROM {q}")
        col_names = [desc[0].lower() for desc in cursor.description]
        while True:
            batch = cursor.fetchmany(chunk_size)
            if not batch:
                break
            for row in batch:
                yield dict(zip(col_names, row))
    else:
        cur = conn.execute(f"SELECT {column_clause} FROM {q}")
        col_names = [desc[0].lower() for desc in cur.description]
        while True:
            batch = cur.fetchmany(chunk_size)
            if not batch:
                break
            for row in batch:
                yield dict(zip(col_names, row))


def fetch_rows_by_ids(conn, db_type, table_name, columns, id_fields, ids):
    """Fetch rows for a set of id values using a VALUES join."""
    if not ids:
        return []
    q = qualified_table(conn, db_type, table_name)
    actual_columns = [get_column_identifier(conn, db_type, table_name, col) for col in columns]
    actual_id_columns = [get_column_identifier(conn, db_type, table_name, col) for col in id_fields]

    ph = _param_placeholder()

    if db_type == 'snowflake':
        # Build IN clause for single id field, or multi-column approach
        if len(actual_id_columns) == 1:
            id_col = actual_id_columns[0]
            select_clause = ", ".join(f't."{col}"' for col in actual_columns)
            placeholders = ", ".join([ph] * len(ids))
            sql = f'SELECT {select_clause} FROM {q} t WHERE t."{id_col}" IN ({placeholders})'
            params = [row.get(id_fields[0]) for row in ids]
        else:
            # For multi-column ids, use OR conditions
            select_clause = ", ".join(f't."{col}"' for col in actual_columns)
            conditions = []
            params = []
            for row in ids:
                cond_parts = []
                for field, col in zip(id_fields, actual_id_columns):
                    cond_parts.append(f't."{col}" = {ph}')
                    params.append(row.get(field))
                conditions.append("(" + " AND ".join(cond_parts) + ")")
            where_clause = " OR ".join(conditions)
            sql = f'SELECT {select_clause} FROM {q} t WHERE {where_clause}'

        cursor = conn.cursor()
        cursor.execute(sql, params)
        col_names = [desc[0].lower() for desc in cursor.description]
        return [dict(zip(col_names, row)) for row in cursor.fetchall()]
    else:
        # DuckDB: use VALUES approach
        values_clause = ", ".join(
            ["(" + ", ".join([ph] * len(actual_id_columns)) + ")"] * len(ids)
        )
        id_cols = ", ".join(f'"{col}"' for col in actual_id_columns)
        select_clause = ", ".join(f't."{col}"' for col in actual_columns)
        join_condition = " AND ".join(
            f't."{col}" = ids."{col}"' for col in actual_id_columns
        )
        sql = (
            f"WITH ids({id_cols}) AS (VALUES {values_clause}) "
            f"SELECT {select_clause} FROM {q} t "
            f"JOIN ids ON {join_condition}"
        )

        params = []
        for row in ids:
            for field in id_fields:
                params.append(row.get(field))

        cur = conn.execute(sql, params)
        col_names = [desc[0].lower() for desc in cur.description]
        return [dict(zip(col_names, row)) for row in cur.fetchall()]


def assert_rows_match_for_ids(table_name, expected_rows, id_fields, ids):
    """Compare expected rows to actual rows by id-based selection."""
    if not expected_rows:
        raise AssertionError(f"No expected rows provided for {table_name}")
    columns = list(expected_rows[0].keys())
    expected_counts = Counter(row_signature(row, columns) for row in expected_rows)

    conn, db_type = get_connection()
    try:
        actual_rows = fetch_rows_by_ids(conn, db_type, table_name, columns, id_fields, ids)
    finally:
        conn.close()

    actual_counts = Counter(row_signature(row, columns) for row in actual_rows)

    if actual_counts != expected_counts:
        missing = sum((expected_counts - actual_counts).values())
        extra = sum((actual_counts - expected_counts).values())
        raise AssertionError(
            f"Row mismatch for {table_name}: missing={missing} extra={extra}"
        )


def assert_rows_match_full(table_name, expected_rows):
    """Compare full-table actual rows against expected dump rows."""
    if not expected_rows:
        raise AssertionError(f"No expected rows provided for {table_name}")
    columns = list(expected_rows[0].keys())
    expected_counts = Counter(row_signature(row, columns) for row in expected_rows)

    conn, db_type = get_connection()
    try:
        actual_rows = list(iter_rows(conn, db_type, table_name, columns=columns))
    finally:
        conn.close()

    actual_counts = Counter(row_signature(row, columns) for row in actual_rows)
    if actual_counts != expected_counts:
        missing = sum((expected_counts - actual_counts).values())
        extra = sum((actual_counts - expected_counts).values())
        raise AssertionError(
            f"Row mismatch for {table_name}: missing={missing} extra={extra}"
        )


def validate_columns(model_name, required_columns):
    """Validate that all required columns exist in the model."""
    conn, db_type = get_connection()
    try:
        schema = get_table_schema(conn, db_type, model_name)
        ph = _param_placeholder()
        query = f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = lower({ph})
              AND lower(table_name) = lower({ph})
        """
        cols = execute_query(conn, db_type, query, [schema, model_name])
        col_names = {c[0].lower() for c in cols}
        missing = {c.lower() for c in required_columns} - col_names
        assert not missing, f"Missing columns in {model_name}: {missing}"
        print(f"All required columns present for {model_name}")
    finally:
        conn.close()


def load_manifest():
    """Load dbt manifest.json produced after dbt runs."""
    project_dir = get_dbt_project_dir()
    manifest_path = Path(project_dir) / "target" / "manifest.json"
    assert manifest_path.exists(), f"manifest.json not found at {manifest_path}"
    return json.loads(manifest_path.read_text())


def find_model_node(manifest, model_name):
    """Find a model node entry in the dbt manifest."""
    for node_id, node in manifest.get("nodes", {}).items():
        if node.get("resource_type") == "model" and node.get("name") == model_name:
            return node_id, node
    raise AssertionError(f"Model not found in manifest: {model_name}")


def dependency_model_names(manifest, node):
    """Return model dependency names for a manifest node."""
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


def expected_relation_type(model_name):
    """Determine the expected relation type from dbt materialization."""
    manifest = load_manifest()
    _, node = find_model_node(manifest, model_name)
    materialized = (node.get("config", {}).get("materialized") or "").lower()
    if materialized == "view":
        return "VIEW"
    if materialized in {"table", "incremental", "snapshot"}:
        return "BASE TABLE"
    return None


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Run dbt once for the module to materialize test models."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module", params=MODEL_NAMES)
def model_name(request):
    """Provide each model name for shared structure tests."""
    return request.param


@pytest.fixture(scope="module")
def expected_row_counts():
    """Load expected row counts for all models."""
    pfx = _sf_prefix()
    return load_expected_row_counts(EXPECTED_DIR / f"{pfx}model_row_counts.json")


@pytest.fixture(scope="module")
def expected_columns(model_name):
    """Return column names based on expected dump files."""
    if model_name in SAMPLED_MODELS:
        info = load_expected_rows(get_model_specs()[model_name]["expected_rows"])
        return list(info["rows"][0].keys())
    if model_name in FULL_DUMP_MODELS:
        info = load_expected_full_rows(get_full_dump_specs()[model_name]["expected_rows"])
        return list(info["rows"][0].keys())
    raise AssertionError(f"Unexpected model for expected columns: {model_name}")


@pytest.fixture(scope="module", params=SAMPLED_MODELS)
def sampled_model_name(request):
    """Provide sample-based model names with id/row fixtures."""
    return request.param


@pytest.fixture(scope="module")
def model_spec(sampled_model_name):
    """Return expected file paths for sampled models."""
    return get_model_specs()[sampled_model_name]


@pytest.fixture(scope="module")
def expected_rows_info(model_spec, sampled_model_name):
    """Load expected sampled rows and validate table metadata."""
    info = load_expected_rows(model_spec["expected_rows"])
    if info.get("table") and info["table"] != sampled_model_name:
        raise AssertionError(
            f"Expected rows table mismatch: {info['table']} != {sampled_model_name}"
        )
    return info


@pytest.fixture(scope="module")
def expected_rows(expected_rows_info):
    """Expose the expected sampled rows list."""
    return expected_rows_info["rows"]


@pytest.fixture(scope="module")
def expected_ids_info(model_spec, sampled_model_name):
    """Load expected ids and validate table metadata."""
    info = load_expected_ids(model_spec["expected_ids"])
    if info.get("table") and info["table"] != sampled_model_name:
        raise AssertionError(
            f"Expected ids table mismatch: {info['table']} != {sampled_model_name}"
        )
    return info


@pytest.fixture(scope="module", params=FULL_DUMP_MODELS)
def full_dump_model_name(request):
    """Provide full-dump models with complete expected data."""
    return request.param


@pytest.fixture(scope="module")
def full_dump_rows_info(full_dump_model_name):
    """Load full-dump expected rows for KPI models."""
    return load_expected_full_rows(
        get_full_dump_specs()[full_dump_model_name]["expected_rows"]
    )


@pytest.fixture(scope="module")
def full_dump_rows(full_dump_rows_info):
    """Expose full-dump expected rows for comparison."""
    return full_dump_rows_info["rows"]


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_expected_files_consistent(self, expected_rows_info, expected_ids_info, sampled_model_name):
        """Ensure sampled expected rows and ids have matching counts."""
        assert expected_rows_info["count"] == expected_ids_info["count"], (
            f"Expected rows/ids count mismatch for {sampled_model_name}: "
            f"{expected_rows_info['count']} != {expected_ids_info['count']}"
        )

    def test_columns_exist(self, dbt_run, model_name, expected_columns):
        """Validate required columns exist for each model."""
        print("\n" + "=" * 50)
        print("PHASE 1: Structure and Basic Validation")
        print("=" * 50)
        validate_columns(model_name, expected_columns)

    def test_relation_exists(self, dbt_run, model_name):
        """Validate the model is a view or table."""
        conn, db_type = get_connection()
        try:
            relation_type = get_relation_type(conn, db_type, model_name)
            expected_type = expected_relation_type(model_name)
            if expected_type is not None:
                assert relation_type.upper() == expected_type, (
                    f"Unexpected relation type for {model_name}: {relation_type}"
                )
        finally:
            conn.close()

    def test_non_empty(self, dbt_run, model_name):
        """Validate each model produces at least one row."""
        count = fetch_row_count(model_name)
        assert count > 0, f"{model_name} returned zero rows"
        print(f"{model_name} rows: {count}")

    def test_row_counts_match(self, dbt_run, model_name, expected_row_counts):
        """Validate row counts match the expected agentic outputs."""
        expected = expected_row_counts.get(model_name)
        assert expected is not None, f"Missing expected row count for {model_name}"
        actual = fetch_row_count(model_name)
        assert actual == expected, (
            f"Row count mismatch for {model_name}: {actual} != {expected}"
        )


class TestPhase2Data:
    """Phase 2: Validate data accuracy and business logic."""

    def test_expected_ids_present(self, dbt_run, sampled_model_name, expected_ids_info):
        """Validate sampled ids are present in the target model."""
        id_fields = expected_ids_info["id_fields"]
        ids = expected_ids_info["ids"]
        conn, db_type = get_connection()
        try:
            actual_rows = fetch_rows_by_ids(
                conn, db_type, sampled_model_name, id_fields, id_fields, ids
            )
        finally:
            conn.close()

        expected_id_set = {
            tuple(row[field] for field in id_fields) for row in ids
        }
        actual_id_set = {
            tuple(row[field] for field in id_fields) for row in actual_rows
        }

        missing = expected_id_set - actual_id_set
        extra = actual_id_set - expected_id_set
        assert not missing, (
            f"Missing expected ids in {sampled_model_name}: {list(missing)[:5]}"
        )
        assert not extra, (
            f"Unexpected ids in {sampled_model_name}: {list(extra)[:5]}"
        )
        assert len(actual_rows) == len(ids), (
            f"Expected {len(ids)} rows for {sampled_model_name} sample ids, "
            f"got {len(actual_rows)}"
        )

    def test_expected_rows_match(self, dbt_run, sampled_model_name, expected_rows, expected_ids_info):
        """Compare sampled rows against expected values by id."""
        assert_rows_match_for_ids(
            sampled_model_name,
            expected_rows,
            expected_ids_info["id_fields"],
            expected_ids_info["ids"],
        )

    def test_full_dump_matches(self, dbt_run, full_dump_model_name, full_dump_rows):
        """Validate the full KPI report dump against expected rows."""
        assert_rows_match_full(full_dump_model_name, full_dump_rows)


class TestPhase3DbtArtifacts:
    """Phase 3: Validate dbt artifacts and model metadata."""

    def test_model_in_manifest(self, dbt_run, model_name):
        """Confirm each model exists in the dbt manifest."""
        manifest = load_manifest()
        find_model_node(manifest, model_name)

    def test_no_sources_used(self, dbt_run, model_name):
        """Ensure models do not depend directly on raw sources."""
        manifest = load_manifest()
        _, node = find_model_node(manifest, model_name)
        dependencies = set(node.get("depends_on", {}).get("nodes", []))
        source_nodes = set(manifest.get("sources", {}).keys())
        used_sources = dependencies.intersection(source_nodes)
        assert not used_sources, f"{model_name} depends on sources: {used_sources}"

    def test_dependencies_are_allowed(self, dbt_run, model_name):
        """Validate model dependencies stay within the allowed list."""
        manifest = load_manifest()
        _, node = find_model_node(manifest, model_name)
        dep_names = dependency_model_names(manifest, node)
        extra = {name for name in dep_names if name not in ALLOWED_DEPENDENCIES}
        assert not extra, f"Unexpected refs in {model_name} dependencies: {extra}"


class TestPhase4Idempotency:
    """Phase 4: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, dbt_run):
        """Re-run dbt and compare row counts for stability."""
        print("\n" + "=" * 50)
        print("PHASE 4: Idempotency Test")
        print("=" * 50)

        counts_before = {model: fetch_row_count(model) for model in MODEL_NAMES}
        run_dbt_pipeline()
        counts_after = {model: fetch_row_count(model) for model in MODEL_NAMES}

        assert counts_after == counts_before
        print("Idempotency verified for review moderation trust-risk models")
