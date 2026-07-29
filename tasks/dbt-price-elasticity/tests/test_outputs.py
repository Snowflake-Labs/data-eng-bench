"""
Test verifier for Price Elasticity Analysis task.
Multi-phase testing:
  Phase 1: Schema and structure validation
  Phase 2: Data quality validation
  Phase 3: Business rule validation
  Phase 4: Elasticity coefficient validation
  Phase 5: Idempotency test
"""
import subprocess
import os
from collections import Counter
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
        # Try password auth first (many Snowflake accounts use password, not private key)
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


# ============ CONFIGURATION ============

def _get_schema():
    """Return the schema where models are materialized."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'elasticity_analytics'


SCHEMA = _get_schema()
DBT_PROJECT_PATH = get_dbt_project_dir()


# ============ HELPERS ============

def run_cmd(cmd, cwd=None):
    """Run a shell command and return the result."""
    if cwd is None:
        cwd = DBT_PROJECT_PATH
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt deps + dbt run."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    deps_result = run_cmd("dbt deps --profiles-dir .")
    assert deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}"
    dbt_cmd = "dbt run --profiles-dir . --target dev"
    if db_type == 'snowflake':
        dbt_cmd += " --select +product_elasticity"
    result = run_cmd(dbt_cmd)
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_product_elasticity(conn, db_type):
    """Query product_elasticity model."""
    rows = execute_query(conn, db_type, f"""
        SELECT
            product_id,
            elasticity_coefficient,
            elasticity_type,
            num_observations,
            avg_price,
            avg_quantity
        FROM {SCHEMA}.product_elasticity
        ORDER BY product_id
    """)
    return rows


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def db_conn():
    """Database connection fixture."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    try:
        conn.close()
    except Exception:
        pass  # Connection may already be closed by idempotency test


@pytest.fixture(scope="module")
def elasticity_rows(dbt_run, db_conn):
    """Fixture that provides product_elasticity rows after dbt run."""
    conn, db_type = db_conn
    return query_product_elasticity(conn, db_type)


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_table_exists(self, dbt_run, db_conn):
        """Validate product_elasticity table exists."""
        print("\n" + "="*50)
        print("PHASE 1: Structure and Basic Validation")
        print("="*50)

        conn, db_type = db_conn
        tables = execute_query(conn, db_type, f"""
            SELECT table_name
            FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'product_elasticity'
        """)
        assert len(tables) == 1, "Table product_elasticity does not exist in schema " + SCHEMA
        print(f"Table {SCHEMA}.product_elasticity exists")

    def test_columns_exist(self, dbt_run, db_conn):
        """Validate required columns exist in product_elasticity."""
        conn, db_type = db_conn
        cols = execute_query(conn, db_type, f"""
            SELECT lower(column_name)
            FROM information_schema.columns
            WHERE lower(table_schema) = lower('{SCHEMA}')
            AND lower(table_name) = 'product_elasticity'
        """)
        col_names = {c[0] for c in cols}
        required = {
            "product_id", "elasticity_coefficient", "elasticity_type",
            "num_observations", "avg_price", "avg_quantity"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in product_elasticity: {missing}"
        print(f"All required columns present: {required}")

    def test_has_rows(self, elasticity_rows):
        """Validate table has data."""
        assert len(elasticity_rows) > 0, "No rows in product_elasticity table"
        print(f"Row count: {len(elasticity_rows)}")


class TestPhase2DataQuality:
    """Phase 2: Validate data quality constraints."""

    def test_no_nulls_critical(self, elasticity_rows):
        """Validate no NULL values in critical columns."""
        print("\n" + "="*50)
        print("PHASE 2: Data Quality Validation")
        print("="*50)

        for row in elasticity_rows:
            product_id, elasticity_coef, elasticity_type, num_obs = row[0], row[1], row[2], row[3]
            assert product_id is not None, "NULL product_id found"
            assert elasticity_coef is not None, f"NULL elasticity_coefficient found for {product_id}"
            assert elasticity_type is not None, f"NULL elasticity_type found for {product_id}"
            assert num_obs is not None, f"NULL num_observations found for {product_id}"
        print("No NULL values in critical columns")

    def test_unique_products(self, elasticity_rows):
        """Validate exactly one row per product."""
        product_ids = [row[0] for row in elasticity_rows]
        duplicates = [pid for pid, count in Counter(product_ids).items() if count > 1]
        assert not duplicates, f"Duplicate product_ids found: {duplicates[:5]}"
        print(f"All {len(elasticity_rows)} products are unique")


class TestPhase3BusinessRules:
    """Phase 3: Validate business rules are followed."""

    def test_valid_elasticity_types(self, elasticity_rows):
        """Validate elasticity_type values are valid."""
        print("\n" + "="*50)
        print("PHASE 3: Business Rules Validation")
        print("="*50)

        valid_types = {'elastic', 'inelastic', 'unit_elastic'}
        for row in elasticity_rows:
            elasticity_type = row[2]
            assert elasticity_type in valid_types, \
                f"Invalid elasticity_type '{elasticity_type}' for product {row[0]}"
        print("All elasticity_type values are valid")

    def test_minimum_observations(self, elasticity_rows):
        """Validate minimum observations requirement (>= 3)."""
        for row in elasticity_rows:
            num_obs = int(row[3])
            assert num_obs >= 3, f"Product {row[0]} has only {num_obs} observations (min 3 required)"
        print("All products have at least 3 observations")

    def test_elasticity_capped(self, elasticity_rows):
        """Validate elasticity coefficient is capped between -10 and 10."""
        for row in elasticity_rows:
            elasticity_coef = float(row[1])
            assert -10 <= elasticity_coef <= 10, \
                f"Product {row[0]} has elasticity {elasticity_coef} outside [-10, 10] range"
        print("All elasticity coefficients are within [-10, 10] range")

    def test_classification_logic(self, elasticity_rows):
        """Validate elasticity classification logic is correct."""
        for row in elasticity_rows:
            elasticity_coef = float(row[1])
            elasticity_type = row[2]
            abs_coef = abs(elasticity_coef)

            # Check unit_elastic: abs value within 0.01 of 1.0
            is_unit = abs(abs_coef - 1.0) <= 0.01
            # Check elastic: abs value > 1.0
            is_elastic = abs_coef > 1.0
            # Check inelastic: abs value < 1.0
            is_inelastic = abs_coef < 1.0

            if elasticity_type == 'unit_elastic':
                assert is_unit, f"Product {row[0]} classified as unit_elastic but |e|={abs_coef}"
            elif elasticity_type == 'elastic':
                assert is_elastic and not is_unit, \
                    f"Product {row[0]} classified as elastic but |e|={abs_coef}"
            elif elasticity_type == 'inelastic':
                assert is_inelastic and not is_unit, \
                    f"Product {row[0]} classified as inelastic but |e|={abs_coef}"
        print("Elasticity classification logic is correct")

    def test_positive_prices(self, elasticity_rows):
        """Validate avg_price is positive where not null."""
        for row in elasticity_rows:
            avg_price = row[4]
            if avg_price is not None:
                assert float(avg_price) > 0, f"Product {row[0]} has non-positive avg_price: {avg_price}"
        print("All avg_price values are positive")


class TestPhase4ElasticityValues:
    """Phase 4: Validate elasticity calculations."""

    def test_elasticity_distribution(self, elasticity_rows):
        """Validate reasonable distribution of elasticity types."""
        print("\n" + "="*50)
        print("PHASE 4: Elasticity Values Validation")
        print("="*50)

        type_counts = Counter(row[2] for row in elasticity_rows)
        print(f"Elasticity type distribution: {dict(type_counts)}")

        # Should have at least some of each type (or at least elastic/inelastic)
        total = len(elasticity_rows)
        assert total >= 3, f"Too few products with valid elasticity: {total}"
        print(f"Total products with elasticity: {total}")

    def test_sample_values(self, elasticity_rows):
        """Display sample of elasticity values for verification."""
        print("\nTop 10 products by observations:")
        sorted_rows = sorted(elasticity_rows, key=lambda x: -int(x[3]))[:10]
        for row in sorted_rows:
            pid = str(row[0])[:8] if len(str(row[0])) > 8 else str(row[0])
            print(f"  {pid}... : e={float(row[1]):.4f}, type={row[2]}, obs={int(row[3])}")


class TestPhase5Idempotency:
    """Phase 5: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, elasticity_rows, db_conn):
        """Test that re-running dbt produces the same results."""
        print("\n" + "="*50)
        print("PHASE 5: Idempotency Test")
        print("="*50)

        # Store current results
        rows_before = list(elasticity_rows)

        # For DuckDB, close the module-scoped connection before re-running dbt
        # to avoid file lock conflicts (DuckDB doesn't allow concurrent access)
        conn, db_type = db_conn
        if db_type == 'duckdb':
            conn.close()

        # Re-run dbt
        run_dbt_pipeline()

        # Get new results with a fresh connection
        conn2, db_type2 = get_db_connection()
        try:
            rows_after = query_product_elasticity(conn2, db_type2)
        finally:
            conn2.close()

        # Compare
        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        # Compare row by row (sorted by product_id)
        for before, after in zip(rows_before, rows_after):
            assert str(before[0]) == str(after[0]), f"Product ID mismatch: {before[0]} vs {after[0]}"
            # Allow small floating point differences
            for i in range(1, len(before)):
                if before[i] is not None and after[i] is not None:
                    if isinstance(before[i], (int, float)) or hasattr(before[i], '__float__'):
                        assert abs(float(before[i]) - float(after[i])) < 0.1, \
                            f"Value changed for {before[0]} col {i}: {before[i]} -> {after[i]}"
                    else:
                        assert str(before[i]) == str(after[i]), \
                            f"Value changed for {before[0]} col {i}: {before[i]} -> {after[i]}"

        print(f"Idempotency verified: {len(rows_after)} rows unchanged after re-run")
        print("Phase 5 PASSED")
