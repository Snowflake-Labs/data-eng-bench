"""
Verifier for the dbt_consolidate ads data standardization and union task.

Tests validate project structure, dbt pipeline execution, schema correctness,
deduplication, data integrity, dbt test artifacts, and idempotency across
both DuckDB and Snowflake backends.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import hashlib
import json
import shutil
import os


# ============ DUAL-BACKEND INFRASTRUCTURE ============


def load_snowflake_env():
    """Load Snowflake environment variables from the entrypoint-generated file."""
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
    """Decode the base64-encoded Snowflake private key for key-pair authentication."""
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
    """Create a database connection based on DB_TYPE environment variable.

    Returns a tuple of (connection, db_type_string) where db_type_string
    is either 'snowflake' or 'duckdb'.
    """
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
        db_path = os.environ.get('CONSOLIDATE_DB_PATH', '/app/consolidate.duckdb')
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def execute_query(conn, db_type, query, params=None):
    """Execute a SQL query and return all result rows as a list of tuples."""
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
    """Execute a query and return the single scalar value from the first row/column."""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


def get_dbt_project_dir():
    """Return the dbt project directory path (always /app/dbt_consolidate for this task)."""
    return '/app/dbt_consolidate'


# ============ CONFIGURATION ============


PROJECT_DIR = Path("/app/dbt_consolidate")
DB_PATH = Path("/app/consolidate.duckdb")
SEED_DIR = PROJECT_DIR / "seeds"
PRIVATE_DATA_DIR = Path(__file__).parent / "private_data"
PRIVATE_SEED_FILES = {
    "googleads.csv": "googleads_hidden.csv",
    "metaads.csv": "metaads_hidden.csv",
    "tiktokads.csv": "tiktokads_hidden.csv",
}

DB_TYPE = os.environ.get('DB_TYPE', 'duckdb').lower()

# Schema name for queries - on Snowflake all models go to 'ANALYTICS' (uppercase),
# on DuckDB they go to 'analytics' (lowercase). We use lower() in info_schema queries.
SCHEMA = "analytics"


# ============ HELPERS ============


def run_cmd(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a subprocess command and surface stdout/stderr on failure."""
    process = subprocess.run(args, cwd=str(PROJECT_DIR), capture_output=True, text=True)
    if check and process.returncode != 0:
        sys.stderr.write(process.stdout)
        sys.stderr.write(process.stderr)
        raise RuntimeError(f"Command failed: {' '.join(args)}")
    return process


def require(condition: bool, message: str) -> None:
    """Raise an AssertionError with a descriptive failure message if condition is False."""
    if not condition:
        raise AssertionError(message)


def file_hash(path):
    """Compute SHA256 hash of a file to detect tampering."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def sync_private_seeds() -> None:
    """Copy protected fixtures into the dbt seeds directory for deterministic runs."""
    SEED_DIR.mkdir(parents=True, exist_ok=True)
    for public_name, private_name in PRIVATE_SEED_FILES.items():
        shutil.copyfile(PRIVATE_DATA_DIR / private_name, SEED_DIR / public_name)


def ensure_immutability_of_files():
    """Verify dbt seed files match protected private fixtures to prevent data tampering."""
    for public_name, private_name in PRIVATE_SEED_FILES.items():
        require(
            file_hash(SEED_DIR / public_name) == file_hash(PRIVATE_DATA_DIR / private_name),
            f"{public_name} altered",
        )


# ============ PROJECT STRUCTURE VERIFICATION ============


def verify_structure() -> None:
    """Verify the dbt project layout and required model/seed files exist.

    Checks that the project directory, dbt_project.yml, profiles.yml,
    all three staging models, the intermediate model, and all three seed
    files are present.
    """
    require(PROJECT_DIR.is_dir(), f"Missing project directory: {PROJECT_DIR}")
    require((PROJECT_DIR / "dbt_project.yml").is_file(), "dbt_project.yml not found")
    require(
        (PROJECT_DIR / "profiles.yml").is_file(),
        "profiles.yml missing at project directory",
    )

    # Check staging models
    require(
        (PROJECT_DIR / "models/staging/stg__ads_googleads.sql").is_file(),
        "Missing stg__ads_googleads.sql",
    )
    require(
        (PROJECT_DIR / "models/staging/stg__ads_metaads.sql").is_file(),
        "Missing stg__ads_metaads.sql",
    )
    require(
        (PROJECT_DIR / "models/staging/stg__ads_tiktokads.sql").is_file(),
        "Missing stg__ads_tiktokads.sql",
    )

    # Check int models
    require(
        (PROJECT_DIR / "models/int/int__ads_unified.sql").is_file(),
        "Missing int__ads_unified.sql",
    )

    # Check seeds exist
    require((SEED_DIR / "googleads.csv").is_file(), "Missing googleads.csv seed")
    require((SEED_DIR / "metaads.csv").is_file(), "Missing metaads.csv seed")
    require((SEED_DIR / "tiktokads.csv").is_file(), "Missing tiktokads.csv seed")


# ============ DBT PIPELINE ============


def run_dbt_pipeline(reset_db: bool = False) -> None:
    """Run dbt deps/seed/run end-to-end and verify idempotency.

    The second dbt run checks that models can be rebuilt without errors
    and no state leaks across runs. Uses --select for explicit model selection.
    """
    if reset_db and DB_PATH.exists() and DB_TYPE == 'duckdb':
        DB_PATH.unlink()

    sync_private_seeds()

    run_cmd([
        "dbt", "deps",
        "--project-dir", str(PROJECT_DIR),
        "--profiles-dir", str(PROJECT_DIR),
    ])

    run_cmd([
        "dbt", "seed",
        "--project-dir", str(PROJECT_DIR),
        "--profiles-dir", str(PROJECT_DIR),
    ])

    # Run with explicit --select
    run_cmd([
        "dbt", "run",
        "--select", "stg__ads_googleads", "stg__ads_metaads", "stg__ads_tiktokads", "int__ads_unified",
        "--project-dir", str(PROJECT_DIR),
        "--profiles-dir", str(PROJECT_DIR),
    ])
    # Run twice to verify idempotency
    run_cmd([
        "dbt", "run",
        "--select", "stg__ads_googleads", "stg__ads_metaads", "stg__ads_tiktokads", "int__ads_unified",
        "--project-dir", str(PROJECT_DIR),
        "--profiles-dir", str(PROJECT_DIR),
    ])

    run_cmd([
        "dbt", "test",
        "--project-dir", str(PROJECT_DIR),
        "--profiles-dir", str(PROJECT_DIR),
    ])


def ensure_dbt_packages_installation() -> None:
    """Ensure the dbt_utils package was installed by dbt deps."""
    require(
        (PROJECT_DIR / "dbt_packages" / "dbt_utils").is_dir(),
        "dbt_utils package failed to install",
    )


# ============ SCHEMA VERIFICATION ============


EXPECTED_STAGING_COLS = {"ad_date", "clicks", "impressions", "views", "conversions"}
EXPECTED_INT_COLS = {"source", "ad_date", "clicks", "impressions", "views", "conversions"}


def get_model_columns(conn, db_type, model_name: str) -> set:
    """Query column names from information_schema for a given model.

    Uses lower() on both table_schema and table_name to handle
    Snowflake's uppercase identifier storage.
    """
    query = """
        SELECT lower(column_name)
        FROM information_schema.columns
        WHERE lower(table_schema) = lower(%s)
          AND lower(table_name) = lower(%s)
        ORDER BY lower(column_name)
    """
    if db_type == 'duckdb':
        query = query.replace('%s', '?')
    rows = execute_query(conn, db_type, query, [SCHEMA, model_name])
    return {row[0] for row in rows}


def verify_schema(conn, db_type) -> None:
    """Assert staging and intermediate model columns match the expected sets.

    This enforces the canonical column contract for downstream consumers.
    """
    for model_name in ["stg__ads_googleads", "stg__ads_metaads", "stg__ads_tiktokads"]:
        cols = get_model_columns(conn, db_type, model_name)
        require(
            EXPECTED_STAGING_COLS.issubset(cols),
            f"Schema of {model_name} incorrect. Expected {EXPECTED_STAGING_COLS}, got {cols}",
        )

    int_cols = get_model_columns(conn, db_type, "int__ads_unified")
    require(
        EXPECTED_INT_COLS.issubset(int_cols),
        f"Schema of int__ads_unified incorrect. Expected {EXPECTED_INT_COLS}, got {int_cols}",
    )


# ============ DEDUPLICATION VERIFICATION ============


def try_get_dupes(conn, db_type, model_name: str, columns: list[str]) -> None:
    """Find duplicate rows for the given key columns in a model.

    Deduplication is a core requirement, so any duplicates should fail the test.
    """
    cols = ",".join(columns)
    query = f"""
        SELECT {cols}, COUNT(*) as cnt
        FROM {SCHEMA}.{model_name}
        GROUP BY {cols}
        HAVING COUNT(*) > 1
    """
    dupes = execute_query(conn, db_type, query)
    require(len(dupes) == 0, f"Duplicate rows in {model_name}: {dupes}")


def validate_dupes(conn, db_type) -> None:
    """Ensure staging and intermediate models are deduped on required keys.

    This confirms the task's deduplication requirement was implemented correctly.
    """
    try_get_dupes(conn, db_type, "stg__ads_googleads", ["ad_date"])
    try_get_dupes(conn, db_type, "stg__ads_metaads", ["ad_date"])
    try_get_dupes(conn, db_type, "stg__ads_tiktokads", ["ad_date"])
    try_get_dupes(conn, db_type, "int__ads_unified", ["source", "ad_date"])


# ============ DATA VALIDATION ============


def get_data(conn, db_type, model_name: str) -> list[tuple[str, ...]]:
    """Retrieve ordered, stringified rows from a model for deterministic comparison.

    Converts all values to strings via TO_VARCHAR (Snowflake) or CAST (DuckDB)
    to ensure consistent comparison across backends.
    """
    if model_name == "int__ads_unified":
        cols = "source, ad_date, clicks, impressions, views, conversions"
        order_by = "source, ad_date"
    else:
        cols = "ad_date, clicks, impressions, views, conversions"
        order_by = "ad_date"
    query = f"SELECT {cols} FROM {SCHEMA}.{model_name} ORDER BY {order_by}"
    rows = execute_query(conn, db_type, query)
    return [tuple(str(v) for v in row) for row in rows]


def get_expected_rows() -> list[tuple[str, ...]]:
    """Return the known-good expected rows for the int__ads_unified model.

    These values are derived from the protected private seed data.
    """
    rows = [
        ('google', '2025-12-01', '10', '100', '55', '1'),
        ('google', '2025-12-02', '12', '1050', '70', '2'),
        ('google', '2025-12-03', '14', '180', '80', '5'),
        ('google', '2025-12-04', '16', '1200', '90', '8'),
        ('google', '2025-12-05', '20', '1080', '200', '10'),
        ('google', '2025-12-06', '10', '500', '520', '25'),
        ('google', '2025-12-07', '80', '1600', '650', '12'),
        ('google', '2025-12-08', '90', '10000', '850', '6'),
        ('google', '2025-12-09', '22', '925', '575', '8'),
        ('google', '2025-12-10', '75', '100', '70', '2'),
        ('meta', '2025-12-01', '110', '1100', '210', '11'),
        ('meta', '2025-12-02', '112', '11050', '240', '12'),
        ('meta', '2025-12-03', '114', '1180', '260', '15'),
        ('meta', '2025-12-04', '116', '11200', '280', '18'),
        ('meta', '2025-12-05', '120', '11080', '1400', '110'),
        ('meta', '2025-12-06', '110', '1500', '2040', '215'),
        ('meta', '2025-12-07', '180', '11600', '2300', '112'),
        ('meta', '2025-12-08', '190', '110000', '2700', '16'),
        ('meta', '2025-12-09', '122', '1925', '2150', '18'),
        ('meta', '2025-12-10', '175', '1100', '240', '12'),
        ('tiktok', '2025-12-01', '110', '155', '55', '11'),
        ('tiktok', '2025-12-02', '112', '170', '70', '12'),
        ('tiktok', '2025-12-03', '114', '180', '80', '15'),
        ('tiktok', '2025-12-04', '116', '190', '90', '18'),
        ('tiktok', '2025-12-05', '120', '1200', '200', '110'),
        ('tiktok', '2025-12-06', '110', '1520', '520', '215'),
        ('tiktok', '2025-12-07', '180', '1650', '650', '112'),
        ('tiktok', '2025-12-08', '190', '1850', '850', '16'),
        ('tiktok', '2025-12-09', '122', '1575', '575', '18'),
        ('tiktok', '2025-12-10', '175', '170', '70', '12'),
    ]
    return rows


def validate_intermediate_data(conn, db_type) -> None:
    """Compare the unified model output to a known-good expected fixture.

    This checks both the union logic and per-source cleaning behavior,
    including views column combination and deduplication.
    """
    expected_rows = sorted(get_expected_rows())
    actual_rows = sorted(get_data(conn, db_type, "int__ads_unified"))
    if actual_rows != expected_rows:
        print("Expected rows:")
        print(expected_rows)
        print("Actual rows:")
        print(actual_rows)
    require(actual_rows == expected_rows, "int__ads_unified output mismatch")


# ============ DBT ARTIFACT CHECKS ============


def check_dbt_artifacts_exist() -> None:
    """Ensure dbt produced manifest.json and run_results.json artifacts.

    These artifacts are used to validate if dbt tests have run successfully.
    """
    manifest_path = PROJECT_DIR / "target" / "manifest.json"
    run_results_path = PROJECT_DIR / "target" / "run_results.json"
    require(manifest_path.is_file(), f"Missing manifest.json at {manifest_path}")
    require(run_results_path.is_file(), f"Missing run_results.json at {run_results_path}")


def check_tests() -> None:
    """Verify dbt tests executed and passed for the unified model.

    Reads the dbt manifest to find tests linked to int__ads_unified,
    then checks run_results to confirm all such tests passed.
    """
    manifest = json.loads((PROJECT_DIR / "target" / "manifest.json").read_text())
    model_ids = {
        node_id
        for node_id, node in manifest["nodes"].items()
        if node["resource_type"] == "model" and node["name"] == "int__ads_unified"
    }
    tests = {
        tid: t for tid, t in manifest["nodes"].items()
        if t["resource_type"] == "test"
        and any(model_id in t["depends_on"]["nodes"] for model_id in model_ids)
    }
    run_results = json.loads((PROJECT_DIR / "target" / "run_results.json").read_text())
    statuses = {
        r["unique_id"]: r["status"]
        for r in run_results["results"]
        if r["unique_id"] in tests
    }
    all_passed = statuses and all(s == "pass" for s in statuses.values())
    require(all_passed, "dbt Tests on int__ads_unified failed")


# ============ MAIN TEST FUNCTION ============


def main() -> int:
    """Run the full validation sequence and return a process exit code.

    Executes the dbt pipeline, then verifies packages, file immutability,
    project structure, schemas, deduplication, data, artifacts, and tests.
    """
    run_dbt_pipeline()
    ensure_dbt_packages_installation()
    ensure_immutability_of_files()
    verify_structure()

    conn, db_type = get_db_connection()
    try:
        verify_schema(conn, db_type)
        validate_dupes(conn, db_type)
        validate_intermediate_data(conn, db_type)
    finally:
        conn.close()

    check_dbt_artifacts_exist()
    check_tests()
    return 0


def test_dbt_consolidate() -> None:
    """End-to-end pytest entrypoint for the dbt consolidation task.

    Running everything in one test keeps the setup/teardown cost predictable
    and ensures the full pipeline is validated atomically.
    """
    main()


if __name__ == "__main__":
    import sys
    try:
        main()
        print("\n" + "=" * 50)
        print("ALL TESTS PASSED!")
        print("=" * 50)
        sys.exit(0)
    except AssertionError as e:
        print(f"\nTEST FAILED: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
