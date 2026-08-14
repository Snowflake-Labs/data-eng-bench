"""
Test verifier for Customer Tier Migration Analysis task.
Multi-phase testing:
  Phase 1: Validate model structure and required columns
  Phase 2: Validate migration matrix calculations
  Phase 3: Validate cohort progression analysis
  Phase 4: Validate velocity metrics
  Phase 5: Validate revenue impact analysis
  Phase 6: Validate retention risk scoring
"""
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
    """Create a database connection based on DB_TYPE environment variable.
    Returns (connection, db_type) tuple."""
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


# ============ HELPERS ============


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


PROJECT_DIR = Path(get_dbt_project_dir())
MODEL_SCHEMA = "main_tier_analytics"


def run_cmd(cmd, cwd=None):
    """Run a shell command and return the result."""
    if cwd is None:
        cwd = str(PROJECT_DIR)
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt deps and dbt run."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    result = run_cmd("dbt run --select tier_migration_matrix cohort_tier_progression tier_velocity_metrics tier_migration_revenue_impact tier_retention_risk")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_source_table(table_name):
    """Return the fully qualified source table name based on db_type."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        if table_name in ('CUSTOMER_TIER_HISTORY', 'CUSTOMER_TIERS'):
            return f"CUSTOMER.{table_name}"
        elif table_name == 'ORDERS':
            return f"ORDERS.{table_name}"
        else:
            _s = 'main'
            return f"{_s}.{table_name}"
    else:
        if table_name in ('CUSTOMER_TIER_HISTORY', 'CUSTOMER_TIERS'):
            return f"customer.{table_name}"
        elif table_name == 'ORDERS':
            return f"orders.{table_name}"
        else:
            return f"main.{table_name}"


def get_expected_transition_count():
    """Get expected total transitions from source data."""
    conn, db_type = get_db_connection()
    try:
        src = get_source_table('CUSTOMER_TIER_HISTORY')
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {src}
            WHERE NEW_TIER_ID IS NOT NULL
        """)
        return int(result)
    finally:
        conn.close()


def get_tier_names():
    """Get valid tier names from database."""
    conn, db_type = get_db_connection()
    try:
        src = get_source_table('CUSTOMER_TIERS')
        result = execute_query(conn, db_type, f"SELECT TIER_NAME FROM {src}")
        return {row[0].strip() if row[0] else row[0] for row in result}
    finally:
        conn.close()


@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


class TestPhase1Structure:
    """Phase 1: Validate model structure."""

    def test_model_files_exist(self, dbt_run):
        """Validate dbt model files exist."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        models_dir = PROJECT_DIR / "models" / "marts" / "tier"
        expected_models = [
            "tier_migration_matrix.sql",
            "cohort_tier_progression.sql",
            "tier_velocity_metrics.sql",
            "tier_migration_revenue_impact.sql",
            "tier_retention_risk.sql"
        ]
        for model in expected_models:
            model_path = models_dir / model
            assert model_path.is_file(), f"Missing model file: {model_path}"

    def test_migration_matrix_columns(self, dbt_run):
        """Validate tier_migration_matrix has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT lower(column_name)
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = 'tier_migration_matrix'
            """)
            col_names = {c[0] for c in cols}
            required = {"from_tier", "to_tier", "customer_count", "avg_days_in_source",
                       "avg_spend_change", "avg_points_change", "migration_rate"}
            missing = required - col_names
            assert not missing, f"Missing columns in tier_migration_matrix: {missing}"
        finally:
            conn.close()

    def test_cohort_progression_columns(self, dbt_run):
        """Validate cohort_tier_progression has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT lower(column_name)
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = 'cohort_tier_progression'
            """)
            col_names = {c[0] for c in cols}
            required = {"cohort_month", "cohort_size", "tier_name", "count_at_30d",
                       "count_at_60d", "count_at_90d", "count_at_180d",
                       "upgrade_rate_90d", "downgrade_rate_90d", "retention_rate_90d"}
            missing = required - col_names
            assert not missing, f"Missing columns in cohort_tier_progression: {missing}"
        finally:
            conn.close()

    def test_velocity_metrics_columns(self, dbt_run):
        """Validate tier_velocity_metrics has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT lower(column_name)
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = 'tier_velocity_metrics'
            """)
            col_names = {c[0] for c in cols}
            required = {"customer_id", "total_tier_changes", "first_change_date",
                       "last_change_date", "tier_changes_per_year", "avg_days_between_changes",
                       "net_tier_movement", "is_fast_mover", "is_churning", "movement_consistency"}
            missing = required - col_names
            assert not missing, f"Missing columns in tier_velocity_metrics: {missing}"
        finally:
            conn.close()

    def test_revenue_impact_columns(self, dbt_run):
        """Validate tier_migration_revenue_impact has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT lower(column_name)
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = 'tier_migration_revenue_impact'
            """)
            col_names = {c[0] for c in cols}
            required = {"from_tier", "to_tier", "transition_count", "avg_revenue_before",
                       "avg_revenue_after", "avg_revenue_lift_pct", "total_revenue_impact"}
            missing = required - col_names
            assert not missing, f"Missing columns in tier_migration_revenue_impact: {missing}"
        finally:
            conn.close()

    def test_retention_risk_columns(self, dbt_run):
        """Validate tier_retention_risk has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT lower(column_name)
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}')
                AND lower(table_name) = 'tier_retention_risk'
            """)
            col_names = {c[0] for c in cols}
            required = {"customer_id", "current_tier", "days_since_last_change",
                       "recent_downgrade", "spend_percentile", "points_trend",
                       "risk_score", "risk_category"}
            missing = required - col_names
            assert not missing, f"Missing columns in tier_retention_risk: {missing}"
        finally:
            conn.close()


class TestPhase2MigrationMatrix:
    """Phase 2: Validate migration matrix calculations."""

    def test_total_transitions_match(self, dbt_run):
        """Validate total transitions match source data."""
        print("\n" + "="*50)
        print("PHASE 2: Migration Matrix Validation")
        print("="*50)
        expected = get_expected_transition_count()
        conn, db_type = get_db_connection()
        try:
            actual = execute_scalar(conn, db_type, f"""
                SELECT SUM(customer_count) FROM {MODEL_SCHEMA}.tier_migration_matrix
            """)
            assert int(actual) == expected, \
                f"Total transitions mismatch: expected {expected}, got {actual}"
            print(f"Total transitions: {actual}")
        finally:
            conn.close()

    def test_migration_rates_sum_to_100(self, dbt_run):
        """Validate migration rates sum to approximately 100%."""
        conn, db_type = get_db_connection()
        try:
            total_rate = execute_scalar(conn, db_type, f"""
                SELECT SUM(migration_rate) FROM {MODEL_SCHEMA}.tier_migration_matrix
            """)
            assert abs(float(total_rate) - 100.0) < 0.5, \
                f"Migration rates should sum to 100%, got {float(total_rate):.2f}%"
        finally:
            conn.close()

    def test_new_tier_handling(self, dbt_run):
        """Validate NULL previous_tier is handled as 'New'."""
        conn, db_type = get_db_connection()
        try:
            src = get_source_table('CUSTOMER_TIER_HISTORY')
            new_in_source = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {src}
                WHERE PREVIOUS_TIER_ID IS NULL AND NEW_TIER_ID IS NOT NULL
            """)

            new_in_result = execute_scalar(conn, db_type, f"""
                SELECT SUM(customer_count) FROM {MODEL_SCHEMA}.tier_migration_matrix
                WHERE from_tier = 'New'
            """)
            new_in_result = int(new_in_result) if new_in_result else 0

            assert new_in_result == int(new_in_source), \
                f"'New' tier count mismatch: expected {new_in_source}, got {new_in_result}"
        finally:
            conn.close()

    def test_valid_tier_names(self, dbt_run):
        """Validate all tier names are valid."""
        valid_tiers = get_tier_names()
        valid_tiers.add('New')

        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT DISTINCT from_tier, to_tier FROM {MODEL_SCHEMA}.tier_migration_matrix
            """)
            for from_tier, to_tier in rows:
                ft = from_tier.strip() if from_tier else from_tier
                tt = to_tier.strip() if to_tier else to_tier
                assert ft in valid_tiers, f"Invalid from_tier: {ft}"
                assert tt in (valid_tiers - {'New'}), f"Invalid to_tier: {tt}"
        finally:
            conn.close()


class TestPhase3CohortProgression:
    """Phase 3: Validate cohort progression analysis."""

    def test_cohort_sizes_positive(self, dbt_run):
        """Validate all cohort sizes are positive."""
        print("\n" + "="*50)
        print("PHASE 3: Cohort Progression Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.cohort_tier_progression
                WHERE cohort_size <= 0
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with non-positive cohort_size"
        finally:
            conn.close()

    def test_progression_rates_range(self, dbt_run):
        """Validate upgrade/downgrade/retention rates are between 0 and 100."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.cohort_tier_progression
                WHERE upgrade_rate_90d < 0 OR upgrade_rate_90d > 100
                   OR downgrade_rate_90d < 0 OR downgrade_rate_90d > 100
                   OR retention_rate_90d < 0 OR retention_rate_90d > 100
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with rates outside 0-100 range"
        finally:
            conn.close()

    def test_rates_sum_approximately_100(self, dbt_run):
        """Validate upgrade + downgrade + retention rates sum to ~100%."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT DISTINCT cohort_month, upgrade_rate_90d, downgrade_rate_90d, retention_rate_90d
                FROM {MODEL_SCHEMA}.cohort_tier_progression
            """)
            for cohort, upgrade, downgrade, retention in rows:
                total = float(upgrade or 0) + float(downgrade or 0) + float(retention or 0)
                # Allow for some tolerance due to customers who couldn't be tracked
                assert total <= 100.5, \
                    f"Cohort {cohort} rates sum to {total:.2f}%, exceeds 100%"
        finally:
            conn.close()

    def test_milestone_counts_non_negative(self, dbt_run):
        """Validate milestone counts are non-negative."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.cohort_tier_progression
                WHERE count_at_30d < 0 OR count_at_60d < 0
                   OR count_at_90d < 0 OR count_at_180d < 0
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with negative milestone counts"
        finally:
            conn.close()


class TestPhase4VelocityMetrics:
    """Phase 4: Validate velocity metrics."""

    def test_customer_count_matches(self, dbt_run):
        """Validate customer count matches source."""
        print("\n" + "="*50)
        print("PHASE 4: Velocity Metrics Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            src = get_source_table('CUSTOMER_TIER_HISTORY')
            expected = execute_scalar(conn, db_type, f"""
                SELECT COUNT(DISTINCT CUSTOMER_ID)
                FROM {src}
                WHERE NEW_TIER_ID IS NOT NULL
            """)

            actual = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_velocity_metrics
            """)

            assert int(actual) == int(expected), \
                f"Customer count mismatch: expected {expected}, got {actual}"
        finally:
            conn.close()

    def test_is_fast_mover_logic(self, dbt_run):
        """Validate is_fast_mover = true when changes > 2."""
        conn, db_type = get_db_connection()
        try:
            incorrect = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_velocity_metrics
                WHERE (total_tier_changes > 2 AND is_fast_mover = false)
                   OR (total_tier_changes <= 2 AND is_fast_mover = true)
            """)
            assert int(incorrect) == 0, f"Found {incorrect} rows with incorrect is_fast_mover flag"
        finally:
            conn.close()

    def test_is_churning_logic(self, dbt_run):
        """Validate is_churning = true when net_tier_movement < 0."""
        conn, db_type = get_db_connection()
        try:
            incorrect = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_velocity_metrics
                WHERE (net_tier_movement < 0 AND is_churning = false)
                   OR (net_tier_movement >= 0 AND is_churning = true)
            """)
            assert int(incorrect) == 0, f"Found {incorrect} rows with incorrect is_churning flag"
        finally:
            conn.close()

    def test_dates_logical(self, dbt_run):
        """Validate first_change_date <= last_change_date."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_velocity_metrics
                WHERE first_change_date > last_change_date
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with first_date > last_date"
        finally:
            conn.close()


class TestPhase5RevenueImpact:
    """Phase 5: Validate revenue impact analysis."""

    def test_transition_counts_match_matrix(self, dbt_run):
        """Validate transition counts match migration matrix."""
        print("\n" + "="*50)
        print("PHASE 5: Revenue Impact Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            matrix_total = execute_scalar(conn, db_type, f"""
                SELECT SUM(customer_count) FROM {MODEL_SCHEMA}.tier_migration_matrix
            """)

            impact_total = execute_scalar(conn, db_type, f"""
                SELECT SUM(transition_count) FROM {MODEL_SCHEMA}.tier_migration_revenue_impact
            """)

            assert int(matrix_total) == int(impact_total), \
                f"Transition count mismatch: matrix={matrix_total}, impact={impact_total}"
        finally:
            conn.close()

    def test_revenue_values_non_negative(self, dbt_run):
        """Validate revenue values are non-negative."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_migration_revenue_impact
                WHERE avg_revenue_before < 0 OR avg_revenue_after < 0
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with negative revenue values"
        finally:
            conn.close()

    def test_revenue_lift_calculation(self, dbt_run):
        """Validate revenue lift is correctly calculated."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT avg_revenue_before, avg_revenue_after, avg_revenue_lift_pct
                FROM {MODEL_SCHEMA}.tier_migration_revenue_impact
                WHERE avg_revenue_before > 0 AND avg_revenue_lift_pct IS NOT NULL
            """)
            for before, after, lift in rows:
                expected_lift = 100.0 * (float(after) - float(before)) / float(before)
                assert abs(float(lift) - expected_lift) < 1.0, \
                    f"Revenue lift mismatch: {lift} vs expected {expected_lift:.2f}"
        finally:
            conn.close()


class TestPhase6RetentionRisk:
    """Phase 6: Validate retention risk scoring."""

    def test_risk_score_range(self, dbt_run):
        """Validate risk_score is between 0 and 100."""
        print("\n" + "="*50)
        print("PHASE 6: Retention Risk Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_retention_risk
                WHERE risk_score < 0 OR risk_score > 100
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with risk_score outside 0-100"
        finally:
            conn.close()

    def test_risk_category_logic(self, dbt_run):
        """Validate risk_category matches risk_score ranges."""
        conn, db_type = get_db_connection()
        try:
            incorrect = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_retention_risk
                WHERE (risk_score <= 25 AND risk_category != 'Low')
                   OR (risk_score >= 26 AND risk_score <= 50 AND risk_category != 'Medium')
                   OR (risk_score >= 51 AND risk_score <= 75 AND risk_category != 'High')
                   OR (risk_score >= 76 AND risk_category != 'Critical')
            """)
            assert int(incorrect) == 0, f"Found {incorrect} rows with incorrect risk_category"
        finally:
            conn.close()

    def test_spend_percentile_range(self, dbt_run):
        """Validate spend_percentile is between 0 and 100."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_retention_risk
                WHERE spend_percentile < 0 OR spend_percentile > 100
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with spend_percentile outside 0-100"
        finally:
            conn.close()

    def test_valid_current_tiers(self, dbt_run):
        """Validate current_tier values are valid."""
        valid_tiers = get_tier_names()
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT DISTINCT current_tier FROM {MODEL_SCHEMA}.tier_retention_risk
            """)
            for row in rows:
                tier = row[0].strip() if row[0] else row[0]
                assert tier in valid_tiers, f"Invalid current_tier: {tier}"
        finally:
            conn.close()

    def test_unique_customers(self, dbt_run):
        """Validate each customer appears once in retention risk."""
        conn, db_type = get_db_connection()
        try:
            duplicates = execute_query(conn, db_type, f"""
                SELECT customer_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.tier_retention_risk
                GROUP BY customer_id
                HAVING COUNT(*) > 1
            """)
            assert len(duplicates) == 0, f"Found duplicate customers in retention_risk: {duplicates}"
        finally:
            conn.close()

    def test_points_trend_values(self, dbt_run):
        """Validate points_trend has expected values."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.tier_retention_risk
                WHERE points_trend NOT IN ('Declining', 'Stable/Growing')
            """)
            assert int(invalid) == 0, f"Found {invalid} rows with invalid points_trend"
        finally:
            conn.close()
