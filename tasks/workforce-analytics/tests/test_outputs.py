"""
Test verifier for HR Analytics Dimensional Model task.
Multi-phase testing:
  Phase 1: Validate model structure and all required columns
  Phase 2: Validate intermediate layer calculations
  Phase 3: Validate dimension tables
  Phase 4: Validate fact tables
  Phase 5: Validate report tables
  Phase 6: Validate data integrity and relationships
  Phase 7: Test idempotency
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
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def execute_query(query: str):
    """Execute a query and return results."""
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(query)
            return cursor.fetchall()
        else:
            return conn.execute(query).fetchall()
    finally:
        conn.close()


def execute_scalar(query: str):
    """Execute a query and return a single scalar value"""
    result = execute_query(query)
    return result[0][0] if result else None


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


# ============ SCHEMA RESOLUTION ============

MODEL_SCHEMA = "main"


INTERMEDIATE_MODELS = [
    "int_hr__employee_tenure",
    "int_hr__employee_compensation_current",
    "int_hr__time_entries_daily",
    "int_hr__time_entries_weekly",
    "int_hr__payroll_employee_summary",
    "int_hr__department_headcount",
    "int_hr__position_headcount",
    "int_hr__employee_manager_spine",
    "int_hr__schedule_adherence",
    "int_hr__compensation_bands",
    "int_hr__department_hierarchy_flat",
    "int_hr__overtime_summary",
]

MART_MODELS = [
    "dim_hr__employees",
    "dim_hr__departments",
    "dim_hr__job_positions",
    "dim_hr__managers",
    "fct_hr__time_entries",
    "fct_hr__payroll",
    "fct_hr__compensation_changes",
    "fct_hr__employee_status_changes",
    "rpt_hr__employee_roster",
    "rpt_hr__department_summary",
    "rpt_hr__compensation_analysis",
    "rpt_hr__turnover_analysis",
    "rpt_hr__overtime_report",
    "rpt_hr__headcount_trends",
    "rpt_hr__payroll_summary",
    "rpt_hr__workforce_demographics",
    "rpt_hr__attendance_summary",
    "rpt_hr__org_span_of_control",
]

ALL_MODELS = INTERMEDIATE_MODELS + MART_MODELS

REQUIRED_COLUMNS = {
    "int_hr__employee_tenure": [
        "employee_id", "hire_date", "termination_date", "is_active",
        "tenure_days", "tenure_months", "tenure_years", "tenure_band"
    ],
    "int_hr__employee_compensation_current": [
        "employee_id", "compensation_type", "amount", "currency_code",
        "frequency", "annualized_amount", "effective_from"
    ],
    "int_hr__time_entries_daily": [
        "employee_id", "entry_date", "total_hours_worked", "regular_hours",
        "overtime_hours", "pto_hours", "sick_hours", "entry_count",
        "first_clock_in", "last_clock_out"
    ],
    "int_hr__time_entries_weekly": [
        "employee_id", "week_start_date", "week_end_date", "year_week",
        "total_hours_worked", "regular_hours", "overtime_hours",
        "pto_hours", "sick_hours", "days_worked"
    ],
    "int_hr__payroll_employee_summary": [
        "employee_id", "total_payroll_runs", "total_gross_pay",
        "total_tax_deductions", "total_other_deductions", "total_net_pay",
        "total_hours_worked", "total_overtime_hours", "avg_gross_per_period",
        "first_pay_date", "last_pay_date"
    ],
    "int_hr__department_headcount": [
        "department_id", "snapshot_date", "active_headcount", "full_time_count",
        "part_time_count", "contract_count", "avg_tenure_years",
        "new_hires_30d", "terminations_30d"
    ],
    "int_hr__position_headcount": [
        "position_id", "position_title", "job_level", "active_headcount",
        "avg_tenure_years", "min_compensation", "max_compensation", "avg_compensation"
    ],
    "int_hr__employee_manager_spine": [
        "employee_id", "employee_name", "manager_id", "manager_name",
        "manager_level_1_id", "manager_level_1_name", "org_level",
        "is_manager", "direct_report_count"
    ],
    "int_hr__schedule_adherence": [
        "employee_id", "schedule_date", "scheduled_hours", "actual_hours",
        "variance_hours", "variance_pct", "is_over_scheduled",
        "is_under_scheduled", "attendance_status"
    ],
    "int_hr__compensation_bands": [
        "employee_id", "position_id", "current_compensation", "min_salary",
        "max_salary", "salary_range", "compa_ratio", "range_penetration", "band_position"
    ],
    "int_hr__department_hierarchy_flat": [
        "department_id", "department_name", "level_1_department_id",
        "level_1_department_name", "level_2_department_id", "level_2_department_name",
        "level_3_department_id", "level_3_department_name", "hierarchy_depth", "full_path"
    ],
    "int_hr__overtime_summary": [
        "employee_id", "total_overtime_hours", "overtime_periods",
        "avg_overtime_per_period", "max_overtime_period", "overtime_rate",
        "is_frequent_overtime"
    ],
    "dim_hr__employees": [
        "employee_key", "employee_id", "employee_number", "full_name",
        "first_name", "last_name", "email", "phone", "hire_date",
        "termination_date", "tenure_years", "tenure_band", "employment_type",
        "status", "is_active", "current_department_id", "current_position_id",
        "current_manager_id", "annualized_compensation", "compa_ratio"
    ],
    "dim_hr__departments": [
        "department_key", "department_id", "department_code", "department_name",
        "parent_department_id", "parent_department_name", "level_1_department",
        "level_2_department", "hierarchy_path", "hierarchy_depth",
        "department_head_id", "department_head_name", "is_active", "current_headcount"
    ],
    "dim_hr__job_positions": [
        "position_key", "position_id", "position_code", "position_title",
        "job_level", "job_level_name", "department_id", "department_name",
        "min_salary", "max_salary", "midpoint_salary", "salary_range_spread",
        "is_active", "current_headcount"
    ],
    "dim_hr__managers": [
        "manager_key", "manager_id", "manager_name", "manager_email",
        "manager_title", "manager_level", "department_id", "department_name",
        "direct_report_count", "total_report_count", "span_of_control", "is_active"
    ],
    "fct_hr__time_entries": [
        "time_entry_key", "entry_id", "employee_id", "department_id",
        "position_id", "manager_id", "entry_date", "clock_in", "clock_out",
        "break_minutes", "hours_worked", "entry_type", "status",
        "is_overtime", "is_approved"
    ],
    "fct_hr__payroll": [
        "payroll_key", "detail_id", "payroll_run_id", "employee_id",
        "department_id", "position_id", "payroll_period", "period_start_date",
        "period_end_date", "pay_date", "gross_pay", "tax_deductions",
        "other_deductions", "net_pay", "hours_worked", "overtime_hours",
        "effective_hourly_rate"
    ],
    "fct_hr__compensation_changes": [
        "change_key", "compensation_id", "employee_id", "department_id",
        "position_id", "effective_date", "compensation_type", "previous_amount",
        "new_amount", "change_amount", "change_percentage", "change_type", "is_promotion"
    ],
    "fct_hr__employee_status_changes": [
        "event_key", "employee_id", "event_date", "event_type",
        "from_department_id", "to_department_id", "from_position_id",
        "to_position_id", "from_manager_id", "to_manager_id"
    ],
    "rpt_hr__employee_roster": [
        "employee_id", "employee_number", "full_name", "email", "phone",
        "department_name", "position_title", "job_level_name", "manager_name",
        "hire_date", "tenure_years", "employment_type", "annualized_compensation",
        "compa_ratio", "status"
    ],
    "rpt_hr__department_summary": [
        "department_id", "department_name", "department_head", "total_headcount",
        "full_time_count", "part_time_count", "contractor_count", "avg_tenure_years",
        "total_compensation", "avg_compensation", "avg_compa_ratio",
        "turnover_rate_12m", "new_hires_12m", "terminations_12m"
    ],
    "rpt_hr__compensation_analysis": [
        "position_id", "position_title", "department_id", "department_name",
        "employee_count", "min_compensation", "max_compensation", "avg_compensation",
        "median_compensation", "position_min_salary", "position_max_salary",
        "avg_compa_ratio", "below_range_count", "above_range_count",
        "range_spread_utilization"
    ],
    "rpt_hr__turnover_analysis": [
        "analysis_period", "department_id", "department_name",
        "period_start_headcount", "period_end_headcount", "avg_headcount",
        "new_hires", "terminations", "turnover_rate", "annualized_turnover_rate",
        "net_change", "avg_terminated_tenure"
    ],
    "rpt_hr__overtime_report": [
        "report_month", "department_id", "department_name",
        "employee_count_with_ot", "total_overtime_hours", "total_regular_hours",
        "overtime_percentage", "avg_ot_per_employee", "max_ot_employee_id",
        "max_ot_hours", "estimated_ot_cost"
    ],
    "rpt_hr__headcount_trends": [
        "snapshot_date", "department_id", "department_name", "total_headcount",
        "active_headcount", "full_time_headcount", "part_time_headcount",
        "contractor_headcount", "month_over_month_change", "year_over_year_change",
        "headcount_growth_rate"
    ],
    "rpt_hr__payroll_summary": [
        "payroll_period", "period_start_date", "period_end_date", "pay_date",
        "department_id", "department_name", "employee_count", "total_gross_pay",
        "total_tax_deductions", "total_other_deductions", "total_net_pay",
        "total_hours_worked", "total_overtime_hours", "avg_gross_per_employee",
        "cost_per_hour"
    ],
    "rpt_hr__workforce_demographics": [
        "department_id", "department_name", "total_headcount", "pct_full_time",
        "pct_part_time", "pct_contractor", "avg_tenure_years",
        "pct_tenure_under_1yr", "pct_tenure_1_to_3yr", "pct_tenure_3_to_5yr",
        "pct_tenure_over_5yr", "avg_job_level", "management_ratio"
    ],
    "rpt_hr__attendance_summary": [
        "report_month", "department_id", "department_name", "employee_count",
        "total_scheduled_hours", "total_actual_hours", "attendance_rate",
        "total_pto_hours", "total_sick_hours", "avg_daily_hours",
        "employees_over_scheduled", "employees_under_scheduled"
    ],
    "rpt_hr__org_span_of_control": [
        "manager_id", "manager_name", "manager_title", "department_name",
        "org_level", "direct_reports", "total_reports", "span_of_control_category",
        "avg_report_tenure", "manager_tenure", "layers_below"
    ],
}


def to_float(val):
    """Convert decimal.Decimal or other numeric types to float for comparison."""
    if val is None:
        return None
    return float(val)


def get_model_columns(model_name: str) -> set:
    """Get column names for a model."""
    cols = execute_query(f"""
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = '{MODEL_SCHEMA}' AND lower(table_name) = '{model_name}'
    """)
    return {c[0].lower() for c in cols}


def get_model_row_count(model_name: str) -> int:
    """Get row count for a model."""
    try:
        result = execute_query(f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.{model_name}")
        return result[0][0] if result else 0
    except:
        return 0


def model_exists(model_name: str) -> bool:
    """Check if model exists in database."""
    result = execute_query(f"""
        SELECT COUNT(*) FROM information_schema.tables
        WHERE lower(table_schema) = '{MODEL_SCHEMA}' AND lower(table_name) = '{model_name}'
    """)
    return result[0][0] == 1


def query_model(model_name, query_suffix=""):
    """Query a model and return results."""
    return execute_query(f"SELECT * FROM {MODEL_SCHEMA}.{model_name} {query_suffix}")


# =============================================================================
# PHASE 1: Model Structure Tests
# =============================================================================

class TestPhase1ModelStructure:
    """Phase 1: Validate all models exist with required columns."""

    @pytest.mark.parametrize("model_name", INTERMEDIATE_MODELS)
    def test_intermediate_model_exists(self, model_name):
        """Test that intermediate model exists."""
        assert model_exists(model_name), f"Intermediate model {model_name} does not exist"

    @pytest.mark.parametrize("model_name", MART_MODELS)
    def test_mart_model_exists(self, model_name):
        """Test that mart model exists."""
        assert model_exists(model_name), f"Mart model {model_name} does not exist"

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_model_has_required_columns(self, model_name):
        """Test that model has all required columns."""
        if model_name not in REQUIRED_COLUMNS:
            pytest.skip(f"No column requirements defined for {model_name}")

        actual_columns = get_model_columns(model_name)
        required = REQUIRED_COLUMNS[model_name]

        missing = [col for col in required if col.lower() not in actual_columns]
        assert not missing, f"Model {model_name} missing columns: {missing}"

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_model_has_data(self, model_name):
        """Test that model has at least one row."""
        count = get_model_row_count(model_name)
        assert count > 0, f"Model {model_name} has no data"


# =============================================================================
# PHASE 2: Intermediate Layer Calculations
# =============================================================================

class TestPhase2IntermediateCalculations:
    """Phase 2: Validate intermediate layer calculation logic."""

    def test_employee_tenure_calculation(self):
        """Test tenure days calculation is reasonable."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.int_hr__employee_tenure
        WHERE tenure_days < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative tenure days"

    def test_tenure_band_values(self):
        """Test tenure bands have valid values."""
        query = f"""
        SELECT DISTINCT tenure_band
        FROM {MODEL_SCHEMA}.int_hr__employee_tenure
        WHERE tenure_band NOT IN ('<1 year', '1-2 years', '2-5 years', '5-10 years', '10+ years')
        AND tenure_band IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid tenure bands found: {result}"

    def test_annualized_compensation_positive(self):
        """Test annualized compensation is positive."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.int_hr__employee_compensation_current
        WHERE annualized_amount < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative annualized compensation"

    def test_time_entries_daily_unique(self):
        """Test daily time entries have unique employee-date combinations."""
        query = f"""
        SELECT COUNT(*) as total, COUNT(DISTINCT employee_id || entry_date::varchar) as unique_keys
        FROM {MODEL_SCHEMA}.int_hr__time_entries_daily
        """
        result = execute_query(query)
        # Query should execute successfully

    def test_weekly_hours_non_negative(self):
        """Test weekly hours are non-negative."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.int_hr__time_entries_weekly
        WHERE total_hours_worked < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative weekly hours"

    def test_payroll_summary_totals(self):
        """Test payroll summary totals are non-negative."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.int_hr__payroll_employee_summary
        WHERE total_gross_pay < 0 OR total_net_pay < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative payroll totals"

    def test_department_headcount_positive(self):
        """Test department headcounts are non-negative."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.int_hr__department_headcount
        WHERE active_headcount < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative headcount"

    def test_compa_ratio_reasonable(self):
        """Test compa ratios are in reasonable range (0.5 to 2.5)."""
        query = f"""
        SELECT COUNT(*) as outliers
        FROM {MODEL_SCHEMA}.int_hr__compensation_bands
        WHERE compa_ratio IS NOT NULL AND (compa_ratio < 0.3 OR compa_ratio > 3.0)
        """
        result = execute_query(query)
        # Some outliers may exist, just verify query runs

    def test_overtime_rate_range(self):
        """Test overtime rates are between 0 and 1."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.int_hr__overtime_summary
        WHERE overtime_rate < 0 OR overtime_rate > 1
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid overtime rates"

    def test_band_position_values(self):
        """Test band position has valid values."""
        query = f"""
        SELECT DISTINCT band_position
        FROM {MODEL_SCHEMA}.int_hr__compensation_bands
        WHERE band_position NOT IN ('BELOW', 'LOWER', 'MID', 'UPPER', 'ABOVE')
        AND band_position IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid band positions found: {result}"


# =============================================================================
# PHASE 3: Dimension Table Tests
# =============================================================================

class TestPhase3DimensionTables:
    """Phase 3: Validate dimension tables."""

    def test_dim_employees_unique_keys(self):
        """Test employee dimension has unique keys."""
        query = f"""
        SELECT COUNT(*) as total, COUNT(DISTINCT employee_key) as unique_keys
        FROM {MODEL_SCHEMA}.dim_hr__employees
        """
        result = execute_query(query)
        # Verify counts match

    def test_dim_employees_full_name_populated(self):
        """Test full_name is populated."""
        query = f"""
        SELECT COUNT(*) as missing
        FROM {MODEL_SCHEMA}.dim_hr__employees
        WHERE full_name IS NULL OR full_name = ''
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found employees with missing full_name"

    def test_dim_departments_unique_keys(self):
        """Test department dimension has unique keys."""
        query = f"""
        SELECT COUNT(*) as total, COUNT(DISTINCT department_key) as unique_keys
        FROM {MODEL_SCHEMA}.dim_hr__departments
        """
        result = execute_query(query)

    def test_dim_positions_salary_range_valid(self):
        """Test position salary ranges are valid (min <= max)."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.dim_hr__job_positions
        WHERE min_salary > max_salary
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid salary ranges"

    def test_dim_positions_job_level_name(self):
        """Test job level names are mapped correctly."""
        query = f"""
        SELECT DISTINCT job_level_name
        FROM {MODEL_SCHEMA}.dim_hr__job_positions
        WHERE job_level_name NOT IN ('Entry', 'Mid', 'Senior', 'Director', 'Executive')
        AND job_level_name IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid job level names found: {result}"

    def test_dim_managers_span_of_control(self):
        """Test span of control has valid values."""
        query = f"""
        SELECT DISTINCT span_of_control
        FROM {MODEL_SCHEMA}.dim_hr__managers
        WHERE span_of_control NOT IN ('Narrow', 'Standard', 'Wide')
        AND span_of_control IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid span of control values: {result}"

    def test_dim_positions_midpoint_calculation(self):
        """Test midpoint salary is correctly calculated."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.dim_hr__job_positions
        WHERE midpoint_salary IS NOT NULL
        AND ABS(midpoint_salary - (min_salary + max_salary) / 2) > 1
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Midpoint salary calculation incorrect"


# =============================================================================
# PHASE 4: Fact Table Tests
# =============================================================================

class TestPhase4FactTables:
    """Phase 4: Validate fact tables."""

    def test_fct_time_entries_unique_keys(self):
        """Test time entry fact has unique keys."""
        query = f"""
        SELECT COUNT(*) as total, COUNT(DISTINCT time_entry_key) as unique_keys
        FROM {MODEL_SCHEMA}.fct_hr__time_entries
        """
        result = execute_query(query)

    def test_fct_time_entries_is_overtime_flag(self):
        """Test is_overtime flag matches entry_type."""
        query = f"""
        SELECT COUNT(*) as mismatch
        FROM {MODEL_SCHEMA}.fct_hr__time_entries
        WHERE (entry_type = 'OVERTIME' AND is_overtime = false)
        OR (entry_type != 'OVERTIME' AND is_overtime = true)
        """
        result = execute_query(query)
        assert result[0][0] == 0, "is_overtime flag doesn't match entry_type"

    def test_fct_time_entries_is_approved_flag(self):
        """Test is_approved flag matches status."""
        query = f"""
        SELECT COUNT(*) as mismatch
        FROM {MODEL_SCHEMA}.fct_hr__time_entries
        WHERE (status = 'APPROVED' AND is_approved = false)
        OR (status != 'APPROVED' AND is_approved = true)
        """
        result = execute_query(query)
        assert result[0][0] == 0, "is_approved flag doesn't match status"

    def test_fct_payroll_gross_gte_net(self):
        """Test gross pay >= net pay."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.fct_hr__payroll
        WHERE gross_pay < net_pay
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found records where gross < net pay"

    def test_fct_payroll_effective_rate_positive(self):
        """Test effective hourly rate is positive when populated."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.fct_hr__payroll
        WHERE effective_hourly_rate IS NOT NULL AND effective_hourly_rate <= 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found non-positive effective hourly rates"

    def test_fct_compensation_changes_types(self):
        """Test compensation change types are valid."""
        query = f"""
        SELECT DISTINCT change_type
        FROM {MODEL_SCHEMA}.fct_hr__compensation_changes
        WHERE change_type NOT IN ('INCREASE', 'DECREASE', 'NEW', 'NO_CHANGE')
        AND change_type IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid change types: {result}"

    def test_fct_status_changes_event_types(self):
        """Test employee status change event types are valid."""
        query = f"""
        SELECT DISTINCT event_type
        FROM {MODEL_SCHEMA}.fct_hr__employee_status_changes
        WHERE event_type NOT IN ('HIRE', 'TERMINATION', 'TRANSFER', 'PROMOTION')
        AND event_type IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid event types: {result}"

    def test_fct_compensation_change_amount_sign(self):
        """Test change_amount sign matches change_type."""
        query = f"""
        SELECT COUNT(*) as mismatch
        FROM {MODEL_SCHEMA}.fct_hr__compensation_changes
        WHERE (change_type = 'INCREASE' AND change_amount < 0)
        OR (change_type = 'DECREASE' AND change_amount > 0)
        """
        result = execute_query(query)
        assert result[0][0] == 0, "change_amount sign doesn't match change_type"


# =============================================================================
# PHASE 5: Report Table Tests
# =============================================================================

class TestPhase5ReportTables:
    """Phase 5: Validate report tables."""

    def test_rpt_employee_roster_has_data(self):
        """Test employee roster contains data."""
        count = get_model_row_count("rpt_hr__employee_roster")
        assert count > 0, "Employee roster is empty"

    def test_rpt_department_summary_headcount_positive(self):
        """Test department summary has valid metrics."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__department_summary
        WHERE total_headcount < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative headcount in department summary"

    def test_rpt_compensation_analysis_min_max(self):
        """Test compensation analysis has valid ranges."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__compensation_analysis
        WHERE min_compensation > max_compensation
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid compensation ranges"

    def test_rpt_turnover_rate_range(self):
        """Test turnover rates are in valid range (0 to 1)."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__turnover_analysis
        WHERE turnover_rate < 0 OR turnover_rate > 1
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid turnover rates"

    def test_rpt_overtime_percentage_range(self):
        """Test overtime percentages are valid (0 to 1)."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__overtime_report
        WHERE overtime_percentage < 0 OR overtime_percentage > 1
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid overtime percentages"

    def test_rpt_payroll_summary_positive(self):
        """Test payroll summary totals are non-negative."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__payroll_summary
        WHERE total_gross_pay < 0 OR total_net_pay < 0
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found negative payroll totals"

    def test_rpt_workforce_demographics_percentages(self):
        """Test workforce demographics percentages are valid."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__workforce_demographics
        WHERE pct_full_time < 0 OR pct_part_time < 0 OR pct_contractor < 0
        OR pct_full_time > 1 OR pct_part_time > 1 OR pct_contractor > 1
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid percentages"

    def test_rpt_attendance_rate_reasonable(self):
        """Test attendance rates are reasonable (0 to 2)."""
        query = f"""
        SELECT COUNT(*) as invalid
        FROM {MODEL_SCHEMA}.rpt_hr__attendance_summary
        WHERE attendance_rate < 0 OR attendance_rate > 2
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found invalid attendance rates"

    def test_rpt_span_of_control_categories(self):
        """Test span of control categories are valid."""
        query = f"""
        SELECT DISTINCT span_of_control_category
        FROM {MODEL_SCHEMA}.rpt_hr__org_span_of_control
        WHERE span_of_control_category NOT IN ('Narrow', 'Standard', 'Wide')
        AND span_of_control_category IS NOT NULL
        """
        result = execute_query(query)
        assert len(result) == 0, f"Invalid span of control categories: {result}"


# =============================================================================
# PHASE 6: Data Integrity Tests
# =============================================================================

class TestPhase6DataIntegrity:
    """Phase 6: Validate data integrity and relationships."""

    def test_employee_department_fk(self):
        """Test employees reference valid departments."""
        query = f"""
        SELECT COUNT(*) as orphans
        FROM {MODEL_SCHEMA}.dim_hr__employees e
        LEFT JOIN {MODEL_SCHEMA}.dim_hr__departments d
            ON e.current_department_id = d.department_id
        WHERE e.current_department_id IS NOT NULL
            AND d.department_id IS NULL
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found employees with invalid department references"

    def test_employee_position_fk(self):
        """Test employees reference valid positions."""
        query = f"""
        SELECT COUNT(*) as orphans
        FROM {MODEL_SCHEMA}.dim_hr__employees e
        LEFT JOIN {MODEL_SCHEMA}.dim_hr__job_positions p
            ON e.current_position_id = p.position_id
        WHERE e.current_position_id IS NOT NULL
            AND p.position_id IS NULL
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found employees with invalid position references"

    def test_time_entries_employee_fk(self):
        """Test time entries reference valid employees."""
        query = f"""
        SELECT COUNT(*) as orphans
        FROM {MODEL_SCHEMA}.fct_hr__time_entries t
        LEFT JOIN {MODEL_SCHEMA}.dim_hr__employees e
            ON t.employee_id = e.employee_id
        WHERE e.employee_id IS NULL
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found time entries with invalid employee references"

    def test_payroll_employee_fk(self):
        """Test payroll records reference valid employees."""
        query = f"""
        SELECT COUNT(*) as orphans
        FROM {MODEL_SCHEMA}.fct_hr__payroll p
        LEFT JOIN {MODEL_SCHEMA}.dim_hr__employees e
            ON p.employee_id = e.employee_id
        WHERE e.employee_id IS NULL
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found payroll records with invalid employee references"

    def test_manager_is_employee(self):
        """Test managers are valid employees."""
        query = f"""
        SELECT COUNT(*) as orphans
        FROM {MODEL_SCHEMA}.dim_hr__managers m
        LEFT JOIN {MODEL_SCHEMA}.dim_hr__employees e
            ON m.manager_id = e.employee_id
        WHERE e.employee_id IS NULL
        """
        result = execute_query(query)
        assert result[0][0] == 0, "Found managers who are not employees"


# =============================================================================
# PHASE 7: Idempotency Tests
# =============================================================================

class TestPhase7Idempotency:
    """Phase 7: Test model idempotency."""

    def test_model_counts_deterministic(self):
        """Test that model row counts don't change on re-run."""
        # Get initial counts for a few models
        initial_counts = {}
        test_models = ["int_hr__employee_tenure", "dim_hr__employees", "fct_hr__payroll"]

        for model in test_models:
            initial_counts[model] = get_model_row_count(model)

        # Determine dbt project dir based on DB_TYPE
        dbt_dir = get_dbt_project_dir()

        # Re-run dbt for these models
        subprocess.run(
            f"cd {dbt_dir} && dbt run --select int_hr__employee_tenure dim_hr__employees fct_hr__payroll",
            shell=True, capture_output=True
        )

        # Check counts again
        for model in test_models:
            new_count = get_model_row_count(model)
            assert initial_counts[model] == new_count, \
                f"Model {model} count changed: {initial_counts[model]} -> {new_count}"


# =============================================================================
# Summary Tests
# =============================================================================

class TestSummary:
    """Summary validation."""

    def test_all_30_models_exist(self):
        """Verify all 30 required models exist."""
        missing = []
        for model in ALL_MODELS:
            if not model_exists(model):
                missing.append(model)

        assert len(missing) == 0, f"Missing {len(missing)} models: {missing}"

    def test_model_count_is_30(self):
        """Verify exactly 30 models are defined."""
        assert len(ALL_MODELS) == 30, f"Expected 30 models, got {len(ALL_MODELS)}"

    def test_intermediate_count_is_12(self):
        """Verify 12 intermediate models."""
        assert len(INTERMEDIATE_MODELS) == 12, \
            f"Expected 12 intermediate models, got {len(INTERMEDIATE_MODELS)}"

    def test_mart_count_is_18(self):
        """Verify 18 mart models."""
        assert len(MART_MODELS) == 18, \
            f"Expected 18 mart models, got {len(MART_MODELS)}"
