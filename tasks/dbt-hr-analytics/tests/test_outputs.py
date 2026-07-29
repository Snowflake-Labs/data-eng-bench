"""Verifier for the DBT HR Analytics challenge."""

from __future__ import annotations

import subprocess
import os
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
            schema='retail',
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
        conn = duckdb.connect(db_path)
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


# ============ CONFIGURATION ============

DB_PATH = Path("/app/database/retail.duckdb")
DBT_PROJECT_PATH = Path("/app/dbt_project")

# Schema names - dbt creates schemas with database prefix
# DuckDB: target schema is 'retail' → retail_staging, retail_intermediate, retail_marts
# Snowflake: target schema is 'retail' → retail_staging, retail_intermediate, retail_marts
def _get_schemas():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'retail_staging', 'retail_intermediate', 'retail_marts'
    return 'retail_staging', 'retail_intermediate', 'retail_marts'

STAGING_SCHEMA, INTERMEDIATE_SCHEMA, MARTS_SCHEMA = _get_schemas()

REQUIRED_STAGING_TABLES = [
    "stg_hr__employees",
    "stg_hr__org_hierarchy",
    "stg_hr__departments",
    "stg_hr__compensation",
    "stg_hr__time_entries",
    "stg_hr__positions",
    "stg_orders",
    "stg_shipments",
]

REQUIRED_INTERMEDIATE_TABLES = [
    "int_hr__employee_hierarchy",
    "int_hr__manager_spans",
    "int_hr__employee_productivity",
    "int_hr__warehouse_productivity",
    "int_hr__compensation_summary",
]

REQUIRED_MART_TABLES = [
    "mart_employee_master",
    "mart_org_structure",
    "mart_department_capacity",
    "mart_manager_effectiveness",
    "mart_workforce_trends",
]

# Column requirements
STG_HR_EMPLOYEES_COLS = {
    "employee_id", "employee_number", "full_name", "email",
    "hire_date", "termination_date", "manager_id", "department_id", "position_id",
    "employment_type", "status", "is_active", "tenure_days", "tenure_years"
}

INT_EMPLOYEE_HIERARCHY_COLS = {
    "employee_id", "employee_number", "full_name", "manager_id", "manager_name",
    "department_id", "position_id", "status",
    "reports_to_manager", "has_terminated_manager"
}

INT_MANAGER_SPANS_COLS = {
    "manager_id", "manager_name", "direct_reports", "total_team_size"
}

MART_EMPLOYEE_MASTER_COLS = {
    "employee_id", "employee_number", "full_name", "email",
    "hire_date", "termination_date", "tenure_years",
    "status", "employment_type",
    "department_id", "department_name",
    "position_id", "position_title", "position_level",
    "manager_id", "manager_name",
    "has_terminated_manager", "total_annual_comp", "last_updated_at"
}

MART_ORG_STRUCTURE_COLS = {
    "employee_id", "full_name", "position_title",
    "manager_id", "manager_name", "department_name",
    "org_level", "direct_reports", "total_team_size",
    "is_manager", "is_overloaded"
}

MART_DEPARTMENT_CAPACITY_COLS = {
    "department_id", "department_name", "manager_name",
    "total_employees", "full_time_employees", "part_time_employees", "contractors",
    "avg_tenure_years", "total_annual_payroll", "avg_comp_per_employee"
}

MART_MANAGER_EFFECTIVENESS_COLS = {
    "manager_id", "manager_name", "department_name", "position_title",
    "direct_reports", "total_team_size", "span_of_control",
    "team_avg_tenure_years", "team_total_comp",
    "is_overloaded", "is_understaffed"
}

MART_WORKFORCE_TRENDS_COLS = {
    "month", "total_employees_active", "total_hours_worked", "avg_hours_per_employee",
    "total_orders_processed", "orders_per_employee", "revenue_per_employee"
}


# ============ HELPERS ============


def _table_exists(conn, db_type, schema: str, table: str) -> bool:
    q = """
    SELECT COUNT(*)
    FROM information_schema.tables
    WHERE LOWER(table_schema) = LOWER(?)
      AND LOWER(table_name) = LOWER(?)
    """
    if db_type == 'snowflake':
        q = q.replace('?', '%s')
    result = execute_query(conn, db_type, q, [schema, table])
    return result[0][0] > 0


def _rowcount(conn, db_type, schema: str, table: str) -> int:
    result = execute_query(conn, db_type, f"SELECT COUNT(*) FROM {schema}.{table}")
    return int(result[0][0])


def _cols(conn, db_type, schema: str, table: str) -> set:
    q = """
    SELECT LOWER(column_name)
    FROM information_schema.columns
    WHERE LOWER(table_schema)=LOWER(?) AND LOWER(table_name)=LOWER(?)
    """
    if db_type == 'snowflake':
        q = q.replace('?', '%s')
    rows = execute_query(conn, db_type, q, [schema, table])
    return {r[0] for r in rows}


def _approx_equal(a: float, b: float, tol: float = 0.01) -> bool:
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    return abs(float(a) - float(b)) <= tol


# ============ FIXTURES ============


@pytest.fixture(scope="session", autouse=True)
def run_dbt():
    """Run dbt commands before tests."""
    assert DBT_PROJECT_PATH.exists(), f"dbt project not found at {DBT_PROJECT_PATH}"
    assert (DBT_PROJECT_PATH / "dbt_project.yml").exists(), "Missing dbt_project.yml"
    assert (DBT_PROJECT_PATH / "profiles.yml").exists(), "Missing profiles.yml"

    # Install dbt package dependencies
    subprocess.run(
        ["dbt", "deps", "--profiles-dir", "."],
        cwd=DBT_PROJECT_PATH,
        check=False,
        capture_output=True,
    )

    # Run dbt
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    dbt_cmd = ["dbt", "run", "--profiles-dir", "."]
    if db_type == 'snowflake':
        dbt_cmd.extend(["--select", "stg_hr__employees stg_hr__org_hierarchy stg_hr__departments stg_hr__compensation stg_hr__time_entries stg_hr__positions stg_orders stg_shipments int_hr__employee_hierarchy int_hr__manager_spans int_hr__employee_productivity int_hr__warehouse_productivity int_hr__compensation_summary mart_employee_master mart_org_structure mart_department_capacity mart_manager_effectiveness mart_workforce_trends"])
    result = subprocess.run(
        dbt_cmd,
        cwd=DBT_PROJECT_PATH,
        check=False,
        capture_output=True,
    )

    if result.returncode != 0:
        print("=== DBT RUN FAILED ===")
        print("STDOUT:", result.stdout.decode())
        print("STDERR:", result.stderr.decode())
        pytest.fail(f"dbt run failed with exit code {result.returncode}")


@pytest.fixture(scope="session")
def db_conn():
    """Database connection (DuckDB or Snowflake)."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


class TestPhase1StagingModels:
    """Phase 1: Verify staging models exist and have correct structure."""

    def test_staging_models_exist(self, db_conn):
        """All staging models must exist."""
        conn, db_type = db_conn
        for table in REQUIRED_STAGING_TABLES:
            assert _table_exists(conn, db_type, STAGING_SCHEMA, table), f"Missing staging table: {table}"

    def test_stg_hr_employees_columns(self, db_conn):
        """stg_hr__employees must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, STAGING_SCHEMA, "stg_hr__employees")
        assert STG_HR_EMPLOYEES_COLS.issubset(cols), \
            f"Missing columns in stg_hr__employees: {STG_HR_EMPLOYEES_COLS - cols}"

    def test_stg_hr_employees_data(self, db_conn):
        """stg_hr__employees must have data and computed fields work."""
        conn, db_type = db_conn
        count = _rowcount(conn, db_type, STAGING_SCHEMA, "stg_hr__employees")
        assert count > 0, "stg_hr__employees is empty"

        # Check computed fields
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total,
                COUNT(CASE WHEN is_active = 1 THEN 1 END) as active_count,
                COUNT(CASE WHEN tenure_days > 0 THEN 1 END) as has_tenure
            FROM {STAGING_SCHEMA}.stg_hr__employees
        """)

        assert result[0][0] > 0, "No employees found"
        assert result[0][1] > 0, "No active employees found"
        assert result[0][2] > 0, "tenure_days not calculated"

    def test_stg_hr_org_hierarchy_current_only(self, db_conn):
        """stg_hr__org_hierarchy should only have current records."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT COUNT(*) FROM {STAGING_SCHEMA}.stg_hr__org_hierarchy
        """)

        assert result[0][0] > 0, "stg_hr__org_hierarchy is empty"


class TestPhase2IntermediateModels:
    """Phase 2: Verify intermediate models exist and have correct grain."""

    def test_intermediate_models_exist(self, db_conn):
        """All intermediate models must exist."""
        conn, db_type = db_conn
        for table in REQUIRED_INTERMEDIATE_TABLES:
            assert _table_exists(conn, db_type, INTERMEDIATE_SCHEMA, table), f"Missing intermediate table: {table}"

    def test_int_employee_hierarchy_columns(self, db_conn):
        """int_hr__employee_hierarchy must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, INTERMEDIATE_SCHEMA, "int_hr__employee_hierarchy")
        assert INT_EMPLOYEE_HIERARCHY_COLS.issubset(cols), \
            f"Missing columns: {INT_EMPLOYEE_HIERARCHY_COLS - cols}"

    def test_int_employee_hierarchy_grain(self, db_conn):
        """int_hr__employee_hierarchy grain is one row per employee_id."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT employee_id) as distinct_employees
            FROM {INTERMEDIATE_SCHEMA}.int_hr__employee_hierarchy
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct employee_ids"

    def test_int_employee_hierarchy_flags_managers(self, db_conn):
        """int_hr__employee_hierarchy correctly flags terminated managers."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {INTERMEDIATE_SCHEMA}.int_hr__employee_hierarchy
            WHERE has_terminated_manager = 1
        """)

        # We know from data exploration there should be some
        assert result[0][0] >= 0, "has_terminated_manager flag not working"

    def test_int_manager_spans_columns(self, db_conn):
        """int_hr__manager_spans must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, INTERMEDIATE_SCHEMA, "int_hr__manager_spans")
        assert INT_MANAGER_SPANS_COLS.issubset(cols), \
            f"Missing columns: {INT_MANAGER_SPANS_COLS - cols}"

    def test_int_manager_spans_grain(self, db_conn):
        """int_hr__manager_spans grain is one row per manager."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT manager_id) as distinct_managers
            FROM {INTERMEDIATE_SCHEMA}.int_hr__manager_spans
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct manager_ids"

    def test_int_manager_spans_direct_reports(self, db_conn):
        """int_hr__manager_spans direct_reports should be positive."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT MIN(direct_reports), MAX(direct_reports)
            FROM {INTERMEDIATE_SCHEMA}.int_hr__manager_spans
        """)

        assert result[0][0] >= 1, "direct_reports should be at least 1 for all managers"
        assert result[0][1] > 0, "No managers found with direct reports"

    def test_int_employee_productivity_grain(self, db_conn):
        """int_hr__employee_productivity grain is one row per (employee_id, month)."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT CONCAT(CAST(employee_id AS VARCHAR), '|', CAST(month AS VARCHAR))) as distinct_keys
            FROM {INTERMEDIATE_SCHEMA}.int_hr__employee_productivity
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct (employee_id, month)"


class TestPhase3MartModels:
    """Phase 3: Verify mart models exist and have correct structure."""

    def test_mart_models_exist(self, db_conn):
        """All mart models must exist."""
        conn, db_type = db_conn
        for table in REQUIRED_MART_TABLES:
            assert _table_exists(conn, db_type, MARTS_SCHEMA, table), f"Missing mart table: {table}"

    def test_mart_employee_master_columns(self, db_conn):
        """mart_employee_master must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, MARTS_SCHEMA, "mart_employee_master")
        assert MART_EMPLOYEE_MASTER_COLS.issubset(cols), \
            f"Missing columns: {MART_EMPLOYEE_MASTER_COLS - cols}"

    def test_mart_employee_master_grain(self, db_conn):
        """mart_employee_master grain is one row per employee_id."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT employee_id) as distinct_employees
            FROM {MARTS_SCHEMA}.mart_employee_master
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct employee_ids"

    def test_mart_employee_master_data_quality_flag(self, db_conn):
        """mart_employee_master includes data quality flag for terminated managers."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total,
                COUNT(CASE WHEN has_terminated_manager = 1 THEN 1 END) as flagged
            FROM {MARTS_SCHEMA}.mart_employee_master
        """)

        assert result[0][0] > 0, "mart_employee_master is empty"
        # Flag should exist and be populated (even if 0)
        assert result[0][1] is not None

    def test_mart_org_structure_columns(self, db_conn):
        """mart_org_structure must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, MARTS_SCHEMA, "mart_org_structure")
        assert MART_ORG_STRUCTURE_COLS.issubset(cols), \
            f"Missing columns: {MART_ORG_STRUCTURE_COLS - cols}"

    def test_mart_org_structure_active_only(self, db_conn):
        """mart_org_structure should only include active employees."""
        conn, db_type = db_conn
        count = _rowcount(conn, db_type, MARTS_SCHEMA, "mart_org_structure")
        assert count > 0, "mart_org_structure is empty"

        # Verify no terminated employees
        result = execute_query(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {MARTS_SCHEMA}.mart_org_structure o
            JOIN {STAGING_SCHEMA}.stg_hr__employees e ON o.employee_id = e.employee_id
            WHERE e.status != 'ACTIVE'
        """)

        assert result[0][0] == 0, "mart_org_structure contains non-ACTIVE employees"

    def test_mart_org_structure_manager_flags(self, db_conn):
        """mart_org_structure correctly identifies managers and overloaded managers."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(CASE WHEN is_manager = 1 THEN 1 END) as managers,
                COUNT(CASE WHEN is_overloaded = 1 THEN 1 END) as overloaded
            FROM {MARTS_SCHEMA}.mart_org_structure
        """)

        assert result[0][0] > 0, "No managers identified"

    def test_mart_department_capacity_columns(self, db_conn):
        """mart_department_capacity must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, MARTS_SCHEMA, "mart_department_capacity")
        assert MART_DEPARTMENT_CAPACITY_COLS.issubset(cols), \
            f"Missing columns: {MART_DEPARTMENT_CAPACITY_COLS - cols}"

    def test_mart_department_capacity_grain(self, db_conn):
        """mart_department_capacity grain is one row per department_id."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT department_id) as distinct_depts
            FROM {MARTS_SCHEMA}.mart_department_capacity
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct department_ids"

    def test_mart_department_capacity_employee_counts(self, db_conn):
        """mart_department_capacity employee counts add up correctly."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                total_employees,
                full_time_employees + part_time_employees + contractors as breakdown_sum
            FROM {MARTS_SCHEMA}.mart_department_capacity
            LIMIT 1
        """)

        if result and result[0][0] is not None:
            assert result[0][0] == result[0][1], \
                "Employee type counts don't add up to total_employees"

    def test_mart_manager_effectiveness_columns(self, db_conn):
        """mart_manager_effectiveness must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, MARTS_SCHEMA, "mart_manager_effectiveness")
        assert MART_MANAGER_EFFECTIVENESS_COLS.issubset(cols), \
            f"Missing columns: {MART_MANAGER_EFFECTIVENESS_COLS - cols}"

    def test_mart_manager_effectiveness_grain(self, db_conn):
        """mart_manager_effectiveness grain is one row per manager."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT manager_id) as distinct_managers
            FROM {MARTS_SCHEMA}.mart_manager_effectiveness
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct manager_ids"

    def test_mart_manager_effectiveness_flags(self, db_conn):
        """mart_manager_effectiveness correctly identifies overloaded and understaffed managers."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                MAX(direct_reports) as max_reports,
                COUNT(CASE WHEN is_overloaded = 1 THEN 1 END) as overloaded_count
            FROM {MARTS_SCHEMA}.mart_manager_effectiveness
        """)

        # If there's a manager with >12 reports, they should be flagged
        if result[0][0] and result[0][0] > 12:
            assert result[0][1] > 0, "Managers with >12 reports not flagged as overloaded"

    def test_mart_workforce_trends_columns(self, db_conn):
        """mart_workforce_trends must have all required columns."""
        conn, db_type = db_conn
        cols = _cols(conn, db_type, MARTS_SCHEMA, "mart_workforce_trends")
        assert MART_WORKFORCE_TRENDS_COLS.issubset(cols), \
            f"Missing columns: {MART_WORKFORCE_TRENDS_COLS - cols}"

    def test_mart_workforce_trends_grain(self, db_conn):
        """mart_workforce_trends grain is one row per month."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) as total_rows,
                COUNT(DISTINCT month) as distinct_months
            FROM {MARTS_SCHEMA}.mart_workforce_trends
        """)

        assert result[0][0] == result[0][1], \
            f"Grain violation: {result[0][0]} rows but {result[0][1]} distinct months"


class TestPhase4DataQuality:
    """Phase 4: Verify data quality and business logic."""

    def test_no_null_employee_ids(self, db_conn):
        """No NULL employee_ids in key tables."""
        conn, db_type = db_conn
        for table in ["mart_employee_master", "mart_org_structure"]:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {MARTS_SCHEMA}.{table}
                WHERE employee_id IS NULL
            """)

            assert result[0][0] == 0, f"{table} contains NULL employee_ids"

    def test_tenure_calculations_reasonable(self, db_conn):
        """Tenure calculations produce reasonable values."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT
                MIN(tenure_years) as min_tenure,
                MAX(tenure_years) as max_tenure,
                AVG(tenure_years) as avg_tenure
            FROM {MARTS_SCHEMA}.mart_employee_master
            WHERE status = 'ACTIVE'
        """)

        assert result[0][0] >= 0, "Negative tenure found"
        assert result[0][1] < 100, "Unreasonable tenure (>100 years)"
        assert result[0][2] > 0, "Average tenure should be positive"

    def test_compensation_data_present(self, db_conn):
        """Some employees have compensation data."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {MARTS_SCHEMA}.mart_employee_master
            WHERE total_annual_comp IS NOT NULL AND total_annual_comp > 0
        """)

        assert result[0][0] > 0, "No employees with compensation data"

    def test_manager_hierarchy_valid(self, db_conn):
        """Manager references point to valid employees."""
        conn, db_type = db_conn
        result = execute_query(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {MARTS_SCHEMA}.mart_org_structure o
            WHERE o.manager_id IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM {STAGING_SCHEMA}.stg_hr__employees e
                  WHERE e.employee_id = o.manager_id
              )
        """)

        assert result[0][0] == 0, "Invalid manager references found"


class TestPhase5Idempotency:
    """Phase 5: Verify dbt run is idempotent."""

    def test_idempotency(self, db_conn):
        """Running dbt a second time produces the same results."""
        conn, db_type = db_conn
        # Get current row counts
        counts_before = {}
        for table in REQUIRED_MART_TABLES:
            counts_before[table] = _rowcount(conn, db_type, MARTS_SCHEMA, table)

        # Close connection to release database lock before running dbt
        conn.close()

        # Run dbt again
        db_type_env = os.environ.get('DB_TYPE', 'duckdb').lower()
        dbt_cmd = ["dbt", "run", "--profiles-dir", "."]
        if db_type_env == 'snowflake':
            dbt_cmd.extend(["--select", "stg_hr__employees stg_hr__org_hierarchy stg_hr__departments stg_hr__compensation stg_hr__time_entries stg_hr__positions stg_orders stg_shipments int_hr__employee_hierarchy int_hr__manager_spans int_hr__employee_productivity int_hr__warehouse_productivity int_hr__compensation_summary mart_employee_master mart_org_structure mart_department_capacity mart_manager_effectiveness mart_workforce_trends"])
        result = subprocess.run(
            dbt_cmd,
            cwd=DBT_PROJECT_PATH,
            check=False,
            capture_output=True,
        )
        assert result.returncode == 0, "Second dbt run failed"

        # Reconnect to verify counts
        conn_after, db_type_after = get_db_connection()
        try:
            # Verify counts unchanged
            for table in REQUIRED_MART_TABLES:
                count_after = _rowcount(conn_after, db_type_after, MARTS_SCHEMA, table)
                assert counts_before[table] == count_after, \
                    f"{table} row count changed: {counts_before[table]} -> {count_after}"
        finally:
            conn_after.close()
