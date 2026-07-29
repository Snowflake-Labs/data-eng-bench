"""
Test verifier for Cohort Retention Matrix task.
Multi-phase testing:
  Phase 1: Validate model structure and required columns
  Phase 2: Validate cohort logic and aggregation correctness
  Phase 3: Validate retention calculations
  Phase 4: Validate cumulative and churn metrics
  Phase 5: Test ordering and idempotency
"""
import subprocess
import os
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
            schema='marketing_analytics',
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


# Schema where the model is created (existing project prefixes with main_)
MODEL_SCHEMA = "main_marketing_analytics"
MODEL_NAME = "cohort_retention_matrix"


# ============ HELPERS ============
def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


def get_strftime_expr(db_type, date_expr):
    """Get database-specific STRFTIME/TO_CHAR expression"""
    if db_type == 'snowflake':
        return f"TO_CHAR({date_expr}, 'YYYY-MM')"
    else:
        return f"STRFTIME({date_expr}, '%Y-%m')"


def get_datediff_expr(db_type, unit, start_date, end_date):
    """Get database-specific DATEDIFF/DATE_DIFF expression"""
    if db_type == 'snowflake':
        return f"DATEDIFF('{unit}', {start_date}, {end_date})"
    else:
        return f"DATE_DIFF('{unit}', {start_date}, {end_date})"


def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt deps and dbt run for the cohort_retention_matrix model."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    result = run_cmd("dbt run --select cohort_retention_matrix")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_model():
    """Query cohort_retention_matrix model with all columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                cohort_month,
                acquisition_source,
                cohort_size,
                never_ordered_count,
                m0_retained, m0_revenue, m0_rate,
                m1_retained, m1_revenue, m1_rate, m1_cumulative,
                m2_retained, m2_revenue, m2_rate, m2_cumulative,
                m3_retained, m3_revenue, m3_rate, m3_cumulative,
                m6_retained, m6_revenue, m6_rate, m6_cumulative,
                m12_retained, m12_revenue, m12_rate, m12_cumulative,
                early_churned_count,
                cohort_ltv,
                avg_days_to_second_purchase
            FROM {MODEL_SCHEMA}.{MODEL_NAME}
            ORDER BY cohort_month, acquisition_source
        """)
        return rows
    finally:
        conn.close()


def get_expected_cohort_sizes():
    """Calculate expected cohort sizes from source (all customers including non-ordering)."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    try:
        result = execute_query(conn, db_type, f"""
            WITH customer_cohorts AS (
                SELECT
                    {strftime_expr} as cohort_month,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source,
                    CUSTOMER_ID
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            )
            SELECT
                cc.cohort_month,
                cc.acquisition_source,
                COUNT(DISTINCT cc.CUSTOMER_ID) as cohort_size
            FROM customer_cohorts cc
            JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
            GROUP BY cc.cohort_month, cc.acquisition_source
            ORDER BY cc.cohort_month, cc.acquisition_source
        """)
        return {(r[0], r[1]): r[2] for r in result}
    finally:
        conn.close()


def get_expected_never_ordered():
    """Calculate expected never_ordered_count from source."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    try:
        result = execute_query(conn, db_type, f"""
            WITH valid_orders AS (
                SELECT DISTINCT CUSTOMER_ID
                FROM ORDERS.ORDERS
                WHERE STATUS = 'COMPLETED'
                AND (TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (SAMPLE_ORDER_FLAG IS NULL OR COALESCE(CAST(SAMPLE_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (INTERNAL_ORDER_FLAG IS NULL OR COALESCE(CAST(INTERNAL_ORDER_FLAG AS INTEGER), 0) = 0)
            ),
            customer_cohorts AS (
                SELECT
                    CUSTOMER_ID,
                    {strftime_expr} as cohort_month,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            )
            SELECT
                cc.cohort_month,
                cc.acquisition_source,
                COUNT(DISTINCT CASE WHEN vo.CUSTOMER_ID IS NULL THEN cc.CUSTOMER_ID END) as never_ordered
            FROM customer_cohorts cc
            JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
            LEFT JOIN valid_orders vo ON cc.CUSTOMER_ID = vo.CUSTOMER_ID
            GROUP BY cc.cohort_month, cc.acquisition_source
        """)
        return {(r[0], r[1]): r[2] for r in result}
    finally:
        conn.close()


def get_expected_m0_retention():
    """Calculate expected m0 retention from source."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    try:
        result = execute_query(conn, db_type, f"""
            WITH valid_orders AS (
                SELECT CUSTOMER_ID, DATE_TRUNC('month', ORDERED_AT) as order_month
                FROM ORDERS.ORDERS
                WHERE STATUS = 'COMPLETED'
                AND (TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (SAMPLE_ORDER_FLAG IS NULL OR COALESCE(CAST(SAMPLE_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (INTERNAL_ORDER_FLAG IS NULL OR COALESCE(CAST(INTERNAL_ORDER_FLAG AS INTEGER), 0) = 0)
            ),
            customer_cohorts AS (
                SELECT
                    CUSTOMER_ID,
                    {strftime_expr} as cohort_month,
                    DATE_TRUNC('month', CREATED_AT) as cohort_month_date,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            )
            SELECT
                cc.cohort_month,
                cc.acquisition_source,
                COUNT(DISTINCT CASE
                    WHEN vo.order_month = cc.cohort_month_date THEN cc.CUSTOMER_ID
                END) as m0_retained
            FROM customer_cohorts cc
            JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
            LEFT JOIN valid_orders vo ON cc.CUSTOMER_ID = vo.CUSTOMER_ID
            GROUP BY cc.cohort_month, cc.acquisition_source
        """)
        return {(r[0], r[1]): r[2] for r in result}
    finally:
        conn.close()


def get_expected_m1_retention():
    """Calculate expected m1 retention from source (1 month after signup)."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    datediff_expr = get_datediff_expr(db_type, 'month', 'cc.cohort_month_date', 'vo.order_month')
    try:
        result = execute_query(conn, db_type, f"""
            WITH valid_orders AS (
                SELECT CUSTOMER_ID, DATE_TRUNC('month', ORDERED_AT) as order_month
                FROM ORDERS.ORDERS
                WHERE STATUS = 'COMPLETED'
                AND (TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (SAMPLE_ORDER_FLAG IS NULL OR COALESCE(CAST(SAMPLE_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (INTERNAL_ORDER_FLAG IS NULL OR COALESCE(CAST(INTERNAL_ORDER_FLAG AS INTEGER), 0) = 0)
            ),
            customer_cohorts AS (
                SELECT
                    CUSTOMER_ID,
                    {strftime_expr} as cohort_month,
                    DATE_TRUNC('month', CREATED_AT) as cohort_month_date,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            )
            SELECT
                cc.cohort_month,
                cc.acquisition_source,
                COUNT(DISTINCT CASE
                    WHEN {datediff_expr} = 1 THEN cc.CUSTOMER_ID
                END) as m1_retained
            FROM customer_cohorts cc
            JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
            LEFT JOIN valid_orders vo ON cc.CUSTOMER_ID = vo.CUSTOMER_ID
            GROUP BY cc.cohort_month, cc.acquisition_source
        """)
        return {(r[0], r[1]): r[2] for r in result}
    finally:
        conn.close()


def get_expected_m1_cumulative():
    """Calculate expected m1_cumulative (customers who ordered in m0 OR m1)."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    datediff_expr = get_datediff_expr(db_type, 'month', 'cc.cohort_month_date', 'vo.order_month')
    try:
        result = execute_query(conn, db_type, f"""
            WITH valid_orders AS (
                SELECT CUSTOMER_ID, DATE_TRUNC('month', ORDERED_AT) as order_month
                FROM ORDERS.ORDERS
                WHERE STATUS = 'COMPLETED'
                AND (TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (SAMPLE_ORDER_FLAG IS NULL OR COALESCE(CAST(SAMPLE_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (INTERNAL_ORDER_FLAG IS NULL OR COALESCE(CAST(INTERNAL_ORDER_FLAG AS INTEGER), 0) = 0)
            ),
            customer_cohorts AS (
                SELECT
                    CUSTOMER_ID,
                    {strftime_expr} as cohort_month,
                    DATE_TRUNC('month', CREATED_AT) as cohort_month_date,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            )
            SELECT
                cc.cohort_month,
                cc.acquisition_source,
                COUNT(DISTINCT CASE
                    WHEN {datediff_expr} BETWEEN 0 AND 1 THEN cc.CUSTOMER_ID
                END) as m1_cumulative
            FROM customer_cohorts cc
            JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
            LEFT JOIN valid_orders vo ON cc.CUSTOMER_ID = vo.CUSTOMER_ID
            GROUP BY cc.cohort_month, cc.acquisition_source
        """)
        return {(r[0], r[1]): r[2] for r in result}
    finally:
        conn.close()


def get_expected_early_churned():
    """Calculate expected early_churned_count (ordered in m0 but never again)."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    datediff_expr = get_datediff_expr(db_type, 'month', 'cc.cohort_month_date', 'vo.order_month')
    try:
        result = execute_query(conn, db_type, f"""
            WITH valid_orders AS (
                SELECT CUSTOMER_ID, DATE_TRUNC('month', ORDERED_AT) as order_month
                FROM ORDERS.ORDERS
                WHERE STATUS = 'COMPLETED'
                AND (TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (SAMPLE_ORDER_FLAG IS NULL OR COALESCE(CAST(SAMPLE_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (INTERNAL_ORDER_FLAG IS NULL OR COALESCE(CAST(INTERNAL_ORDER_FLAG AS INTEGER), 0) = 0)
            ),
            customer_cohorts AS (
                SELECT
                    CUSTOMER_ID,
                    {strftime_expr} as cohort_month,
                    DATE_TRUNC('month', CREATED_AT) as cohort_month_date,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            ),
            customer_order_months AS (
                SELECT
                    cc.CUSTOMER_ID,
                    cc.cohort_month,
                    cc.acquisition_source,
                    MIN({datediff_expr}) as min_month,
                    MAX({datediff_expr}) as max_month
                FROM customer_cohorts cc
                JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
                JOIN valid_orders vo ON cc.CUSTOMER_ID = vo.CUSTOMER_ID
                GROUP BY cc.CUSTOMER_ID, cc.cohort_month, cc.acquisition_source
            )
            SELECT
                cohort_month,
                acquisition_source,
                COUNT(DISTINCT CASE WHEN min_month = 0 AND max_month = 0 THEN CUSTOMER_ID END) as early_churned
            FROM customer_order_months
            GROUP BY cohort_month, acquisition_source
        """)
        return {(r[0], r[1]): r[2] for r in result}
    finally:
        conn.close()


def get_expected_ltv():
    """Calculate expected LTV from source."""
    conn, db_type = get_db_connection()
    strftime_expr = get_strftime_expr(db_type, "DATE_TRUNC('month', CREATED_AT)")
    try:
        result = execute_query(conn, db_type, f"""
            WITH valid_orders AS (
                SELECT CUSTOMER_ID, GRAND_TOTAL
                FROM ORDERS.ORDERS
                WHERE STATUS = 'COMPLETED'
                AND (TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (SAMPLE_ORDER_FLAG IS NULL OR COALESCE(CAST(SAMPLE_ORDER_FLAG AS INTEGER), 0) = 0)
                AND (INTERNAL_ORDER_FLAG IS NULL OR COALESCE(CAST(INTERNAL_ORDER_FLAG AS INTEGER), 0) = 0)
            ),
            customer_cohorts AS (
                SELECT
                    CUSTOMER_ID,
                    {strftime_expr} as cohort_month,
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            ),
            cohort_stats AS (
                SELECT
                    cc.cohort_month,
                    cc.acquisition_source,
                    COUNT(DISTINCT cc.CUSTOMER_ID) as cohort_size,
                    COALESCE(SUM(vo.GRAND_TOTAL), 0) as total_revenue
                FROM customer_cohorts cc
                JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
                LEFT JOIN valid_orders vo ON cc.CUSTOMER_ID = vo.CUSTOMER_ID
                GROUP BY cc.cohort_month, cc.acquisition_source
            )
            SELECT
                cohort_month,
                acquisition_source,
                ROUND(total_revenue / cohort_size, 2) as expected_ltv
            FROM cohort_stats
        """)
        return {(r[0], r[1]): float(r[2]) for r in result}
    finally:
        conn.close()


def get_total_customer_count():
    """Get total customer count after filtering."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, """
            WITH customer_cohorts AS (
                SELECT
                    COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as acquisition_source
                FROM CUSTOMER.CUSTOMERS
            ),
            valid_sources AS (
                SELECT acquisition_source
                FROM customer_cohorts
                GROUP BY acquisition_source
                HAVING COUNT(*) >= 10
            )
            SELECT COUNT(*)
            FROM customer_cohorts cc
            JOIN valid_sources vs ON cc.acquisition_source = vs.acquisition_source
        """)
        return result
    finally:
        conn.close()


# Column indices for the query
COL_COHORT_MONTH = 0
COL_ACQUISITION_SOURCE = 1
COL_COHORT_SIZE = 2
COL_NEVER_ORDERED = 3
COL_M0_RETAINED = 4
COL_M0_REVENUE = 5
COL_M0_RATE = 6
COL_M1_RETAINED = 7
COL_M1_REVENUE = 8
COL_M1_RATE = 9
COL_M1_CUMULATIVE = 10
COL_M2_RETAINED = 11
COL_M2_REVENUE = 12
COL_M2_RATE = 13
COL_M2_CUMULATIVE = 14
COL_M3_RETAINED = 15
COL_M3_REVENUE = 16
COL_M3_RATE = 17
COL_M3_CUMULATIVE = 18
COL_M6_RETAINED = 19
COL_M6_REVENUE = 20
COL_M6_RATE = 21
COL_M6_CUMULATIVE = 22
COL_M12_RETAINED = 23
COL_M12_REVENUE = 24
COL_M12_RATE = 25
COL_M12_CUMULATIVE = 26
COL_EARLY_CHURNED = 27
COL_COHORT_LTV = 28
COL_AVG_DAYS = 29


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def model_rows(dbt_run):
    """Fixture that provides model rows after dbt run."""
    return query_model()


@pytest.fixture(scope="module")
def expected_cohort_sizes():
    """Fixture that provides expected cohort sizes."""
    return get_expected_cohort_sizes()


@pytest.fixture(scope="module")
def expected_never_ordered():
    """Fixture that provides expected never_ordered counts."""
    return get_expected_never_ordered()


@pytest.fixture(scope="module")
def expected_m0_retention():
    """Fixture that provides expected m0 retention."""
    return get_expected_m0_retention()


@pytest.fixture(scope="module")
def expected_m1_retention():
    """Fixture that provides expected m1 retention."""
    return get_expected_m1_retention()


@pytest.fixture(scope="module")
def expected_m1_cumulative():
    """Fixture that provides expected m1 cumulative."""
    return get_expected_m1_cumulative()


@pytest.fixture(scope="module")
def expected_early_churned():
    """Fixture that provides expected early churned counts."""
    return get_expected_early_churned()


@pytest.fixture(scope="module")
def expected_ltv():
    """Fixture that provides expected LTV values."""
    return get_expected_ltv()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and required columns."""

    def test_model_file_exists(self, dbt_run):
        """Validate the model file exists at the expected location."""
        model_path = f"{get_dbt_project_dir()}/models/marts/marketing/cohort_retention_matrix.sql"
        assert os.path.exists(model_path), \
            f"Model file not found at {model_path}. Create the model in models/marts/marketing/"

    def test_model_exists_in_schema(self, dbt_run):
        """Validate the model exists in the correct schema."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = lower('{MODEL_NAME}')
            """)
            assert result == 1, f"Model {MODEL_NAME} not found in schema {MODEL_SCHEMA}"
        finally:
            conn.close()

    def test_all_required_columns_exist(self, dbt_run):
        """Validate all required columns exist."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = lower('{MODEL_NAME}')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                "cohort_month", "acquisition_source", "cohort_size", "never_ordered_count",
                "m0_retained", "m0_revenue", "m0_rate",
                "m1_retained", "m1_revenue", "m1_rate", "m1_cumulative",
                "m2_retained", "m2_revenue", "m2_rate", "m2_cumulative",
                "m3_retained", "m3_revenue", "m3_rate", "m3_cumulative",
                "m6_retained", "m6_revenue", "m6_rate", "m6_cumulative",
                "m12_retained", "m12_revenue", "m12_rate", "m12_cumulative",
                "early_churned_count",
                "cohort_ltv", "avg_days_to_second_purchase"
            }
            missing = required - col_names
            assert not missing, f"Missing columns in {MODEL_NAME}: {missing}"
        finally:
            conn.close()

    def test_has_rows(self, model_rows):
        """Validate model has data."""
        assert len(model_rows) > 0, f"{MODEL_NAME} has no rows"

    def test_cohort_month_format(self, model_rows):
        """Validate cohort_month is in YYYY-MM format."""
        import re
        pattern = re.compile(r'^\d{4}-\d{2}$')
        for row in model_rows:
            cohort = row[COL_COHORT_MONTH]
            assert pattern.match(cohort), f"Cohort month '{cohort}' not in YYYY-MM format"


class TestPhase2CohortLogic:
    """Phase 2: Validate cohort logic and aggregation correctness."""

    def test_cohort_sizes_match_source(self, model_rows, expected_cohort_sizes):
        """Validate cohort sizes match source data (all customers including non-ordering)."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_COHORT_SIZE] for row in model_rows}

        mismatches = []
        for key, expected_size in expected_cohort_sizes.items():
            if key in model_by_key:
                actual_size = model_by_key[key]
                if actual_size != expected_size:
                    mismatches.append(f"{key}: got {actual_size}, expected {expected_size}")

        assert not mismatches, f"Cohort size mismatches:\n" + "\n".join(mismatches[:5])

    def test_total_customers_match(self, model_rows):
        """Validate total customers across all cohorts matches source."""
        actual_total = sum(row[COL_COHORT_SIZE] for row in model_rows)
        expected_total = get_total_customer_count()
        assert actual_total == expected_total, \
            f"Total customer count mismatch: model has {actual_total}, expected {expected_total}"

    def test_never_ordered_matches_source(self, model_rows, expected_never_ordered):
        """Validate never_ordered_count matches source calculations."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_NEVER_ORDERED] for row in model_rows}

        mismatches = []
        for key, expected_val in expected_never_ordered.items():
            if key in model_by_key:
                actual_val = model_by_key[key]
                if actual_val != expected_val:
                    mismatches.append(f"{key}: got {actual_val}, expected {expected_val}")

        assert not mismatches, f"never_ordered_count mismatches:\n" + "\n".join(mismatches[:5])

    def test_acquisition_source_threshold(self, model_rows):
        """Validate only acquisition sources with 10+ customers are included."""
        conn, db_type = get_db_connection()
        try:
            small_sources = execute_query(conn, db_type, """
                SELECT COALESCE(ACQUISITION_SOURCE, 'UNKNOWN') as src, COUNT(*) as cnt
                FROM CUSTOMER.CUSTOMERS
                GROUP BY COALESCE(ACQUISITION_SOURCE, 'UNKNOWN')
                HAVING COUNT(*) < 10
            """)
            excluded_sources = {r[0] for r in small_sources}

            for row in model_rows:
                source = row[COL_ACQUISITION_SOURCE]
                assert source not in excluded_sources, \
                    f"Acquisition source '{source}' has <10 customers and should be excluded"
        finally:
            conn.close()

    def test_one_row_per_cohort_source(self, model_rows):
        """Validate exactly one row per cohort_month + acquisition_source."""
        keys = [(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]) for row in model_rows]
        duplicates = [k for k in keys if keys.count(k) > 1]
        assert not duplicates, f"Duplicate cohort+source combinations: {set(duplicates)}"


class TestPhase3RetentionCalculations:
    """Phase 3: Validate retention calculations."""

    def test_retention_not_higher_than_cohort_size(self, model_rows):
        """Validate retained customers never exceed cohort size."""
        retention_cols = [
            (COL_M0_RETAINED, 'm0'),
            (COL_M1_RETAINED, 'm1'),
            (COL_M2_RETAINED, 'm2'),
            (COL_M3_RETAINED, 'm3'),
            (COL_M6_RETAINED, 'm6'),
            (COL_M12_RETAINED, 'm12'),
        ]
        for row in model_rows:
            cohort_size = row[COL_COHORT_SIZE]
            for col_idx, period in retention_cols:
                retained = row[col_idx]
                assert retained <= cohort_size, \
                    f"Cohort {row[COL_COHORT_MONTH]}/{row[COL_ACQUISITION_SOURCE]}: {period}_retained ({retained}) > cohort_size ({cohort_size})"

    def test_m0_retention_matches_source(self, model_rows, expected_m0_retention):
        """Validate m0 retention values match source calculations."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_M0_RETAINED] for row in model_rows}

        mismatches = []
        for key, expected_m0 in expected_m0_retention.items():
            if key in model_by_key:
                actual_m0 = model_by_key[key]
                if actual_m0 != expected_m0:
                    mismatches.append(f"{key}: got {actual_m0}, expected {expected_m0}")

        assert not mismatches, f"m0_retained mismatches:\n" + "\n".join(mismatches[:5])

    def test_m1_retention_matches_source(self, model_rows, expected_m1_retention):
        """Validate m1 retention values match source calculations."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_M1_RETAINED] for row in model_rows}

        mismatches = []
        for key, expected_m1 in expected_m1_retention.items():
            if key in model_by_key:
                actual_m1 = model_by_key[key]
                if actual_m1 != expected_m1:
                    mismatches.append(f"{key}: got {actual_m1}, expected {expected_m1}")

        assert not mismatches, f"m1_retained mismatches:\n" + "\n".join(mismatches[:5])

    def test_retention_rates_calculated_correctly(self, model_rows):
        """Validate retention rates are calculated as (retained/cohort_size)*100."""
        rate_pairs = [
            (COL_M0_RETAINED, COL_M0_RATE, 'm0'),
            (COL_M1_RETAINED, COL_M1_RATE, 'm1'),
            (COL_M2_RETAINED, COL_M2_RATE, 'm2'),
            (COL_M3_RETAINED, COL_M3_RATE, 'm3'),
            (COL_M6_RETAINED, COL_M6_RATE, 'm6'),
            (COL_M12_RETAINED, COL_M12_RATE, 'm12'),
        ]
        for row in model_rows:
            cohort_size = float(row[COL_COHORT_SIZE] or 0)
            for retained_col, rate_col, period in rate_pairs:
                retained = float(row[retained_col] or 0)
                actual_rate = float(row[rate_col])
                expected_rate = round(retained * 100.0 / cohort_size, 2) if cohort_size > 0 else 0.0
                assert abs(actual_rate - expected_rate) < 0.1, \
                    f"Cohort {row[COL_COHORT_MONTH]}/{row[COL_ACQUISITION_SOURCE]}: {period}_rate {actual_rate} != expected {expected_rate}"

    def test_ltv_calculation_matches(self, model_rows, expected_ltv):
        """Validate cohort_ltv matches expected values."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_COHORT_LTV] for row in model_rows}

        mismatches = []
        for key, expected_val in expected_ltv.items():
            if key in model_by_key:
                actual_val = float(model_by_key[key]) if model_by_key[key] is not None else 0
                if abs(actual_val - expected_val) > 0.1:
                    mismatches.append(f"{key}: got {actual_val}, expected {expected_val}")

        assert not mismatches, f"cohort_ltv mismatches:\n" + "\n".join(mismatches[:5])

    def test_revenue_values_non_negative(self, model_rows):
        """Validate all revenue values are non-negative."""
        revenue_cols = [
            (COL_M0_REVENUE, 'm0'),
            (COL_M1_REVENUE, 'm1'),
            (COL_M2_REVENUE, 'm2'),
            (COL_M3_REVENUE, 'm3'),
            (COL_M6_REVENUE, 'm6'),
            (COL_M12_REVENUE, 'm12'),
        ]
        for row in model_rows:
            for col_idx, period in revenue_cols:
                revenue = row[col_idx]
                assert revenue >= 0, \
                    f"Cohort {row[COL_COHORT_MONTH]}/{row[COL_ACQUISITION_SOURCE]}: {period}_revenue ({revenue}) is negative"


class TestPhase4CumulativeAndChurn:
    """Phase 4: Validate cumulative retention and churn metrics."""

    def test_m1_cumulative_matches_source(self, model_rows, expected_m1_cumulative):
        """Validate m1_cumulative matches source calculations."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_M1_CUMULATIVE] for row in model_rows}

        mismatches = []
        for key, expected_val in expected_m1_cumulative.items():
            if key in model_by_key:
                actual_val = model_by_key[key]
                if actual_val != expected_val:
                    mismatches.append(f"{key}: got {actual_val}, expected {expected_val}")

        assert not mismatches, f"m1_cumulative mismatches:\n" + "\n".join(mismatches[:5])

    def test_cumulative_increases_monotonically(self, model_rows):
        """Validate cumulative retention increases or stays same across periods."""
        cumulative_cols = [
            (COL_M1_CUMULATIVE, 'm1'),
            (COL_M2_CUMULATIVE, 'm2'),
            (COL_M3_CUMULATIVE, 'm3'),
            (COL_M6_CUMULATIVE, 'm6'),
            (COL_M12_CUMULATIVE, 'm12'),
        ]
        for row in model_rows:
            prev_val = row[COL_M0_RETAINED]  # m0 is effectively m0_cumulative
            for col_idx, period in cumulative_cols:
                curr_val = row[col_idx]
                assert curr_val >= prev_val, \
                    f"Cohort {row[COL_COHORT_MONTH]}/{row[COL_ACQUISITION_SOURCE]}: {period}_cumulative ({curr_val}) < previous ({prev_val})"
                prev_val = curr_val

    def test_cumulative_not_higher_than_cohort_size(self, model_rows):
        """Validate cumulative retention never exceeds cohort size."""
        cumulative_cols = [
            (COL_M1_CUMULATIVE, 'm1'),
            (COL_M2_CUMULATIVE, 'm2'),
            (COL_M3_CUMULATIVE, 'm3'),
            (COL_M6_CUMULATIVE, 'm6'),
            (COL_M12_CUMULATIVE, 'm12'),
        ]
        for row in model_rows:
            cohort_size = row[COL_COHORT_SIZE]
            for col_idx, period in cumulative_cols:
                cumulative = row[col_idx]
                assert cumulative <= cohort_size, \
                    f"Cohort {row[COL_COHORT_MONTH]}/{row[COL_ACQUISITION_SOURCE]}: {period}_cumulative ({cumulative}) > cohort_size ({cohort_size})"

    def test_early_churned_matches_source(self, model_rows, expected_early_churned):
        """Validate early_churned_count matches source calculations."""
        model_by_key = {(row[COL_COHORT_MONTH], row[COL_ACQUISITION_SOURCE]): row[COL_EARLY_CHURNED] for row in model_rows}

        mismatches = []
        for key, expected_val in expected_early_churned.items():
            if key in model_by_key:
                actual_val = model_by_key[key]
                if actual_val != expected_val:
                    mismatches.append(f"{key}: got {actual_val}, expected {expected_val}")

        # Only check if we have expected values
        if expected_early_churned:
            assert not mismatches, f"early_churned_count mismatches:\n" + "\n".join(mismatches[:5])

    def test_early_churned_not_higher_than_m0_retained(self, model_rows):
        """Validate early_churned_count never exceeds m0_retained."""
        for row in model_rows:
            m0_retained = row[COL_M0_RETAINED]
            early_churned = row[COL_EARLY_CHURNED]
            assert early_churned <= m0_retained, \
                f"Cohort {row[COL_COHORT_MONTH]}/{row[COL_ACQUISITION_SOURCE]}: early_churned ({early_churned}) > m0_retained ({m0_retained})"

    def test_avg_days_to_second_purchase_reasonable(self, model_rows):
        """Validate avg_days_to_second_purchase values are reasonable."""
        for row in model_rows:
            avg_days = row[COL_AVG_DAYS]
            if avg_days is not None:
                assert avg_days >= 0, f"avg_days_to_second_purchase cannot be negative: {avg_days}"
                assert avg_days <= 3650, f"avg_days_to_second_purchase too high: {avg_days} days"


class TestPhase5Ordering:
    """Phase 5: Validate result ordering."""

    def test_sorted_correctly(self, model_rows):
        """Validate results are sorted by cohort_month, then acquisition_source."""
        for i in range(1, len(model_rows)):
            prev = model_rows[i-1]
            curr = model_rows[i]
            if prev[COL_COHORT_MONTH] > curr[COL_COHORT_MONTH]:
                pytest.fail(f"Not sorted by cohort_month: {prev[COL_COHORT_MONTH]} > {curr[COL_COHORT_MONTH]}")
            elif prev[COL_COHORT_MONTH] == curr[COL_COHORT_MONTH]:
                if prev[COL_ACQUISITION_SOURCE] > curr[COL_ACQUISITION_SOURCE]:
                    pytest.fail(f"Not sorted by acquisition_source: {prev[COL_ACQUISITION_SOURCE]} > {curr[COL_ACQUISITION_SOURCE]}")


class TestPhase6Idempotency:
    """Phase 6: Test idempotency."""

    def test_idempotency(self, model_rows):
        """Test that re-running dbt produces the same results."""
        rows_before = sorted(list(model_rows), key=lambda x: (x[COL_COHORT_MONTH], x[COL_ACQUISITION_SOURCE]))

        run_dbt_pipeline()

        rows_after = sorted(query_model(), key=lambda x: (x[COL_COHORT_MONTH], x[COL_ACQUISITION_SOURCE]))

        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            if before != after:
                for i, (b, a) in enumerate(zip(before, after)):
                    if b == a:
                        continue
                    try:
                        if abs(float(b) - float(a)) < 0.01:
                            continue
                    except (TypeError, ValueError):
                        pass
                    assert False, \
                        f"Row changed after re-run:\nBefore: {before}\nAfter: {after}"
