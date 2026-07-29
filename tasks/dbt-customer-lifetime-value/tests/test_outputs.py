"""
Test verifier for Customer Lifetime Value (CLV) task.
Multi-phase testing with comprehensive validation.
Supports both DuckDB and Snowflake backends.
"""
import subprocess
from collections import Counter
from datetime import date, datetime
from statistics import stdev, mean
import pytest
import re
import math
import os

# ============ CONSTANTS ============

VALID_SEGMENTS = ['Platinum', 'Gold', 'Silver', 'Bronze']
VALID_LIFECYCLE_STAGES = ['New', 'Growing', 'Mature', 'Declining', 'Churned', 'At Risk - High Value']
VALID_VALUE_TRAJECTORIES = ['Accelerating', 'Stable', 'Decelerating']
VALID_VELOCITY_TRENDS = ['Accelerating', 'Stable', 'Slowing', 'Insufficient Data']

ANALYSIS_START_DATE = date(2023, 1, 1)
ANALYSIS_END_DATE = date(2024, 11, 30)
REFERENCE_DATE = date(2024, 12, 1)

EXCLUDED_STATUSES = {'CANCELLED', 'RETURNED', 'FAILED'}

def _to_date(val):
    """Convert a value to datetime.date, handling strings from Snowflake."""
    if isinstance(val, datetime):
        return val.date()
    if isinstance(val, date):
        return val
    if isinstance(val, str):
        return datetime.fromisoformat(val.replace(' ', 'T').split('+')[0]).date()
    return val

NPV_MULTIPLIER = 2.7833  # 1 + 1/1.08 + 1/1.1664

REQUIRED_COLUMNS = [
    "customer_id", "customer_name", "first_order_date", "last_order_date",
    "customer_tenure_days", "days_since_last_order", "total_orders", "total_revenue",
    "avg_order_value", "avg_days_between_orders", "orders_per_year",
    "predicted_annual_revenue", "clv_3_year", "clv_3_year_npv", "clv_segment",
    "is_at_risk", "clv_percentile", "clv_quartile", "lifecycle_stage",
    "first_order_quarter", "value_trajectory", "velocity_trend",
    "churn_probability_score", "revenue_contribution_pct", "cumulative_revenue_pct",
    "revenue_rank", "engagement_score", "expected_next_order_date",
    "days_until_expected_order", "days_overdue"
]

SUMMARY_COLUMNS = [
    "clv_segment", "customer_count", "total_revenue", "avg_clv_3_year",
    "avg_clv_3_year_npv", "avg_orders_per_year", "at_risk_count", "at_risk_percentage",
    "churned_count", "avg_tenure_days", "avg_engagement_score", "avg_churn_probability",
    "accelerating_count", "decelerating_count", "pct_revenue_contribution"
]

COHORT_COLUMNS = [
    "cohort_quarter", "cohort_size", "total_cohort_revenue", "avg_clv_3_year",
    "avg_clv_3_year_npv", "avg_orders", "retention_rate", "at_risk_rate",
    "avg_engagement_score", "avg_churn_probability", "platinum_count",
    "gold_count", "silver_count", "bronze_count", "accelerating_pct", "decelerating_pct"
]

MONTHLY_COLUMNS = [
    "customer_id", "order_month", "monthly_orders", "monthly_revenue",
    "cumulative_orders", "cumulative_revenue", "months_since_first_order",
    "avg_monthly_revenue", "is_active_month", "order_month_rank"
]


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
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE') or '/app/dbt_models_snowflake'
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB') or '/app/dbt_models_duckdb'


# ============ HELPERS ============

def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    dbt_dir = get_dbt_project_dir()
    result = run_cmd(
        "dbt run --select int_clv_customer_orders int_clv_metrics clv_predictions clv_segments clv_segment_summary clv_cohort_analysis clv_monthly_trends",
        cwd=dbt_dir
    )
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_clv_segments():
    conn, db_type = get_db_connection()
    try:
        for schema in ['marts', 'main', 'PUBLIC']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT customer_id, customer_name, first_order_date, last_order_date,
                           customer_tenure_days, days_since_last_order, total_orders,
                           total_revenue, avg_order_value, avg_days_between_orders,
                           orders_per_year, predicted_annual_revenue, clv_3_year,
                           clv_3_year_npv, clv_segment, is_at_risk, clv_percentile,
                           clv_quartile, lifecycle_stage, first_order_quarter,
                           value_trajectory, velocity_trend, churn_probability_score,
                           revenue_contribution_pct, cumulative_revenue_pct,
                           revenue_rank, engagement_score, expected_next_order_date,
                           days_until_expected_order, days_overdue
                    FROM {schema}.clv_segments ORDER BY customer_id
                """)
            except:
                continue
        raise Exception("clv_segments not found")
    finally:
        conn.close()


def query_segment_summary():
    conn, db_type = get_db_connection()
    try:
        for schema in ['marts', 'main', 'PUBLIC']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT clv_segment, customer_count, total_revenue, avg_clv_3_year,
                           avg_clv_3_year_npv, avg_orders_per_year, at_risk_count,
                           at_risk_percentage, churned_count, avg_tenure_days,
                           avg_engagement_score, avg_churn_probability,
                           accelerating_count, decelerating_count, pct_revenue_contribution
                    FROM {schema}.clv_segment_summary ORDER BY avg_clv_3_year DESC
                """)
            except:
                continue
        raise Exception("clv_segment_summary not found")
    finally:
        conn.close()


def query_cohort_analysis():
    conn, db_type = get_db_connection()
    try:
        for schema in ['marts', 'main', 'PUBLIC']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT cohort_quarter, cohort_size, total_cohort_revenue, avg_clv_3_year,
                           avg_clv_3_year_npv, avg_orders, retention_rate, at_risk_rate,
                           avg_engagement_score, avg_churn_probability, platinum_count,
                           gold_count, silver_count, bronze_count, accelerating_pct,
                           decelerating_pct
                    FROM {schema}.clv_cohort_analysis ORDER BY cohort_quarter
                """)
            except:
                continue
        raise Exception("clv_cohort_analysis not found")
    finally:
        conn.close()


def query_monthly_trends():
    conn, db_type = get_db_connection()
    try:
        for schema in ['marts', 'main', 'PUBLIC']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT customer_id, order_month, monthly_orders, monthly_revenue,
                           cumulative_orders, cumulative_revenue, months_since_first_order,
                           avg_monthly_revenue, is_active_month, order_month_rank
                    FROM {schema}.clv_monthly_trends ORDER BY customer_id, order_month
                """)
            except:
                continue
        raise Exception("clv_monthly_trends not found")
    finally:
        conn.close()


def query_customer_orders():
    conn, db_type = get_db_connection()
    try:
        for schema in ['intermediate', 'main', 'PUBLIC']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT customer_id, order_id, ordered_at, grand_total, days_since_previous_order
                    FROM {schema}.int_clv_customer_orders ORDER BY customer_id, ordered_at
                """)
            except:
                continue
        return execute_query(conn, db_type, """
            SELECT customer_id, order_id, ordered_at, grand_total, days_since_previous_order
            FROM int_clv_customer_orders ORDER BY customer_id, ordered_at
        """)
    finally:
        conn.close()


def query_source_orders():
    conn, db_type = get_db_connection()
    try:
        for prefix in ['staging.', 'main.', 'PUBLIC.', '']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT order_id, customer_id, ordered_at, status, test_order_flag
                    FROM {prefix}stg_orders__orders
                """), None
            except:
                continue
        return None, "Could not query source"
    finally:
        conn.close()


def get_table_schema():
    conn, db_type = get_db_connection()
    try:
        for schema in ['marts', 'main', 'PUBLIC']:
            try:
                execute_query(conn, db_type, f"SELECT 1 FROM {schema}.clv_segments LIMIT 1")
                return schema
            except:
                continue
        return None
    finally:
        conn.close()


def get_table_type(schema, table):
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT table_type FROM information_schema.tables
            WHERE lower(table_schema) = lower('{schema}') AND lower(table_name) = lower('{table}')
        """)
        return result[0][0] if result else None
    finally:
        conn.close()


def is_truthy(v):
    if v is None: return False
    if isinstance(v, bool): return v
    if isinstance(v, (int, float)): return v == 1
    if isinstance(v, str): return v.lower() in ('1', 'true', 't')
    return bool(v)


def get_quarter(d):
    """Get quarter string from date."""
    if hasattr(d, 'date'):
        d = d.date()
    q = (d.month - 1) // 3 + 1
    return f"{d.year}-Q{q}"


def get_month_str(d):
    """Get month string YYYY-MM from date."""
    if hasattr(d, 'date'):
        d = d.date()
    return f"{d.year}-{d.month:02d}"


def months_between(d1, d2):
    """Calculate months between two dates."""
    if hasattr(d1, 'date'):
        d1 = d1.date()
    if hasattr(d2, 'date'):
        d2 = d2.date()
    return (d2.year - d1.year) * 12 + (d2.month - d1.month)


# ============ FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True

@pytest.fixture(scope="module")
def clv_rows(dbt_run):
    return query_clv_segments()

@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    return query_segment_summary()

@pytest.fixture(scope="module")
def cohort_rows(dbt_run):
    return query_cohort_analysis()

@pytest.fixture(scope="module")
def monthly_rows(dbt_run):
    return query_monthly_trends()

@pytest.fixture(scope="module")
def customer_orders_rows(dbt_run):
    return query_customer_orders()

@pytest.fixture(scope="module")
def source_orders_result(dbt_run):
    return query_source_orders()

@pytest.fixture(scope="module")
def schema_name(dbt_run):
    return get_table_schema()


# ============ PHASE 1: STRUCTURE ============

class TestPhase1Structure:
    def test_model_exists(self, schema_name):
        """Verify the clv_segments model exists in the database."""
        print("\n" + "="*50 + "\nPHASE 1: Structure\n" + "="*50)
        assert schema_name is not None, "clv_segments not found"

    def test_columns_exist(self, schema_name):
        """Verify all required columns exist in the clv_segments model."""
        conn, db_type = get_db_connection()
        try:
            cols = {c[0].lower() for c in execute_query(conn, db_type, f"""
                SELECT column_name FROM information_schema.columns
                WHERE lower(table_schema) = lower('{schema_name}') AND lower(table_name) = 'clv_segments'
            """)}
            missing = {c.lower() for c in REQUIRED_COLUMNS} - cols
            assert not missing, f"Missing: {missing}"
        finally:
            conn.close()

    def test_no_nulls(self, clv_rows):
        """Verify no NULL values exist in any required column of clv_segments."""
        for row in clv_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL in {REQUIRED_COLUMNS[i]} for {row[0]}"

    def test_unique_customers(self, clv_rows):
        """Verify customer_id values are unique with no duplicates."""
        ids = [r[0] for r in clv_rows]
        dupes = [k for k, v in Counter(ids).items() if v > 1]
        assert not dupes, f"Duplicates: {dupes[:5]}"

    def test_minimum_orders(self, clv_rows):
        """Verify all customers in clv_segments have at least 2 orders."""
        for row in clv_rows:
            assert int(row[6]) >= 2, f"{row[0]} has {row[6]} orders"


# ============ PHASE 2: FILTERING ============

class TestPhase2Filtering:
    def test_excluded_statuses(self, customer_orders_rows, source_orders_result):
        """Verify orders with CANCELLED, RETURNED, or FAILED status are excluded."""
        print("\n" + "="*50 + "\nPHASE 2: Filtering\n" + "="*50)
        src, err = source_orders_result
        assert src, f"Cannot validate: {err}"
        excluded = {r[0] for r in src if r[3] in EXCLUDED_STATUSES}
        clv_ids = {r[1] for r in customer_orders_rows}
        assert not (excluded & clv_ids), "Excluded orders found"

    def test_date_range(self, customer_orders_rows):
        """Verify all order dates fall within the analysis period (2023-01-01 to 2024-11-30)."""
        for row in customer_orders_rows:
            d = _to_date(row[2])
            assert ANALYSIS_START_DATE <= d <= ANALYSIS_END_DATE


# ============ PHASE 3: BASIC METRICS ============

class TestPhase3Metrics:
    def test_positive_metrics(self, clv_rows):
        """Verify tenure, orders, and revenue are positive for all CLV customers."""
        print("\n" + "="*50 + "\nPHASE 3: Metrics\n" + "="*50)
        for r in clv_rows:
            assert int(r[4]) > 0 and int(r[6]) >= 2 and float(r[7]) > 0

    def test_aov_calculation(self, clv_rows):
        """Verify avg_order_value equals total_revenue / total_orders."""
        for r in clv_rows:
            exp = round(float(r[7]) / int(r[6]), 2)
            assert abs(float(r[8]) - exp) < 0.02

    def test_orders_per_year(self, clv_rows):
        """Verify orders_per_year equals 365 / avg_days_between_orders."""
        for r in clv_rows:
            exp = round(365.0 / float(r[9]), 2)
            assert abs(float(r[10]) - exp) < 0.05

    def test_predicted_annual(self, clv_rows):
        """Verify predicted_annual_revenue equals orders_per_year * avg_order_value."""
        for r in clv_rows:
            exp = round(float(r[10]) * float(r[8]), 2)
            assert abs(float(r[11]) - exp) < 1.0

    def test_clv_3_year(self, clv_rows):
        """Verify clv_3_year equals predicted_annual_revenue * 3."""
        for r in clv_rows:
            exp = round(float(r[11]) * 3, 2)
            assert abs(float(r[12]) - exp) < 1.0

    def test_clv_3_year_npv(self, clv_rows):
        """Test NPV calculation with 8% discount rate."""
        for r in clv_rows:
            predicted_annual = float(r[11])
            exp = round(predicted_annual * NPV_MULTIPLIER, 2)
            assert abs(float(r[13]) - exp) < 1.5, f"{r[0]}: NPV {r[13]} != {exp}"

    def test_tenure_days(self, clv_rows):
        """Verify customer_tenure_days equals reference date minus first_order_date."""
        for r in clv_rows:
            first = r[2].date() if hasattr(r[2], 'date') else r[2]
            exp = (REFERENCE_DATE - first).days
            assert int(r[4]) == exp, f"{r[0]}: {r[4]} != {exp}"

    def test_days_since_last(self, clv_rows):
        """Verify days_since_last_order equals reference date minus last_order_date."""
        for r in clv_rows:
            last = r[3].date() if hasattr(r[3], 'date') else r[3]
            exp = (REFERENCE_DATE - last).days
            assert int(r[5]) == exp


# ============ PHASE 4: SEGMENTS ============

class TestPhase4Segments:
    def test_valid_segments(self, clv_rows):
        """Verify all clv_segment values are Platinum, Gold, Silver, or Bronze."""
        print("\n" + "="*50 + "\nPHASE 4: Segments\n" + "="*50)
        for r in clv_rows:
            assert r[14] in VALID_SEGMENTS

    def test_thresholds(self, clv_rows):
        """Verify CLV segment thresholds: Platinum>=5000, Gold 2000-5000, Silver 500-2000, Bronze<500."""
        for r in clv_rows:
            clv, seg = float(r[12]), r[14]
            if seg == 'Platinum': assert clv >= 5000
            elif seg == 'Gold': assert 2000 <= clv < 5000
            elif seg == 'Silver': assert 500 <= clv < 2000
            else: assert clv < 500


# ============ PHASE 5: LAG FUNCTION ============

class TestPhase5LAG:
    def test_lag_exists(self, customer_orders_rows):
        """Verify int_clv_customer_orders model contains data."""
        print("\n" + "="*50 + "\nPHASE 5: LAG\n" + "="*50)
        assert len(customer_orders_rows) > 0

    def test_first_null(self, customer_orders_rows):
        """Verify days_since_previous_order is NULL for each customer's first order."""
        by_cust = {}
        for r in customer_orders_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, orders in by_cust.items():
            if len(orders) >= 2:
                assert orders[0][4] is None

    def test_lag_accuracy(self, customer_orders_rows):
        """Verify days_since_previous_order matches actual day difference between consecutive orders."""
        by_cust = {}
        for r in customer_orders_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, orders in by_cust.items():
            for i in range(1, len(orders)):
                curr = _to_date(orders[i][2])
                prev = _to_date(orders[i-1][2])
                exp = (curr - prev).days
                assert int(orders[i][4]) == exp


# ============ PHASE 6: HEALTH METRICS ============

class TestPhase6Health:
    def test_is_at_risk(self, clv_rows):
        """Verify is_at_risk is true when days_since_last > 2x avg_days_between_orders."""
        print("\n" + "="*50 + "\nPHASE 6: Health\n" + "="*50)
        for r in clv_rows:
            exp = int(r[5]) > (2 * float(r[9]))
            assert is_truthy(r[15]) == exp

    def test_percentile_range(self, clv_rows):
        """Verify clv_percentile is within the 0-100 range for all customers."""
        for r in clv_rows:
            assert 0 <= float(r[16]) <= 100

    def test_quartile_range(self, clv_rows):
        """Verify clv_quartile is 1, 2, 3, or 4 for all customers."""
        for r in clv_rows:
            assert int(r[17]) in [1, 2, 3, 4]

    def test_quartile_ordering(self, clv_rows):
        """Verify quartile 1 CLV values are lower than quartile 4 within each segment."""
        by_seg = {}
        for r in clv_rows:
            by_seg.setdefault(r[14], []).append(r)
        for seg, rows in by_seg.items():
            if len(rows) >= 4:
                sorted_rows = sorted(rows, key=lambda x: float(x[12]))
                q1_clvs = [float(r[12]) for r in sorted_rows if int(r[17]) == 1]
                q4_clvs = [float(r[12]) for r in sorted_rows if int(r[17]) == 4]
                if q1_clvs and q4_clvs:
                    assert max(q1_clvs) <= min(q4_clvs), f"Quartile ordering wrong in {seg}"


# ============ PHASE 7: VALUE TRAJECTORY ============

class TestPhase7ValueTrajectory:
    def test_valid_trajectories(self, clv_rows):
        """Verify all value_trajectory values are Accelerating, Stable, or Decelerating."""
        print("\n" + "="*50 + "\nPHASE 7: Value Trajectory\n" + "="*50)
        for r in clv_rows:
            assert r[20] in VALID_VALUE_TRAJECTORIES, f"Invalid trajectory: {r[20]}"

    def test_trajectory_logic(self, customer_orders_rows, clv_rows):
        """Verify value trajectory calculation."""
        by_cust = {}
        for r in customer_orders_rows:
            by_cust.setdefault(r[0], []).append(r)

        clv_dict = {r[0]: r for r in clv_rows}

        for cid, orders in by_cust.items():
            if cid not in clv_dict:
                continue
            n = len(orders)
            if n < 2:
                continue

            # Calculate first and second half averages
            first_half_end = (n + 1) // 2  # Include middle in first half
            first_half = orders[:first_half_end]
            second_half = orders[first_half_end:]

            if not second_half:
                continue

            first_avg = mean([float(o[3]) for o in first_half])
            second_avg = mean([float(o[3]) for o in second_half])

            if second_avg > first_avg * 1.1:
                exp = 'Accelerating'
            elif second_avg < first_avg * 0.9:
                exp = 'Decelerating'
            else:
                exp = 'Stable'

            actual = clv_dict[cid][20]
            assert actual == exp, f"{cid}: trajectory {actual} != {exp}"


# ============ PHASE 8: VELOCITY TREND ============

class TestPhase8VelocityTrend:
    def test_valid_trends(self, clv_rows):
        """Verify all velocity_trend values are in the allowed set."""
        print("\n" + "="*50 + "\nPHASE 8: Velocity Trend\n" + "="*50)
        for r in clv_rows:
            assert r[21] in VALID_VELOCITY_TRENDS, f"Invalid trend: {r[21]}"

    def test_insufficient_data(self, clv_rows):
        """Customers with 2-3 orders should have 'Insufficient Data'."""
        for r in clv_rows:
            if int(r[6]) <= 3:
                assert r[21] == 'Insufficient Data', f"{r[0]}: {r[6]} orders but trend={r[21]}"

    def test_velocity_logic(self, customer_orders_rows, clv_rows):
        """Verify velocity trend calculation for 4+ order customers."""
        by_cust = {}
        for r in customer_orders_rows:
            by_cust.setdefault(r[0], []).append(r)

        clv_dict = {r[0]: r for r in clv_rows}

        for cid, orders in by_cust.items():
            if cid not in clv_dict:
                continue
            n = len(orders)
            if n < 4:
                continue

            # Get gaps (days_since_previous_order for orders 2+)
            gaps = [int(o[4]) for o in orders[1:] if o[4] is not None]
            if len(gaps) < 3:
                continue

            # Recent = last 2 gaps, Historical = all gaps except last 2
            recent_gaps = gaps[-2:]
            historical_gaps = gaps[:-2]

            if not historical_gaps:
                continue

            recent_avg = mean(recent_gaps)
            historical_avg = mean(historical_gaps)

            if recent_avg < historical_avg * 0.8:
                exp = 'Accelerating'
            elif recent_avg > historical_avg * 1.2:
                exp = 'Slowing'
            else:
                exp = 'Stable'

            actual = clv_dict[cid][21]
            assert actual == exp, f"{cid}: velocity {actual} != {exp}"


# ============ PHASE 9: CHURN PROBABILITY ============

class TestPhase9ChurnProbability:
    def test_score_range(self, clv_rows):
        """Verify churn_probability_score is within the 0-100 range for all customers."""
        print("\n" + "="*50 + "\nPHASE 9: Churn Probability\n" + "="*50)
        for r in clv_rows:
            score = float(r[22])
            assert 0 <= score <= 100, f"{r[0]}: score {score} out of range"

    def test_churn_score_logic(self, clv_rows):
        """Verify churn probability calculation."""
        for r in clv_rows:
            days_since = int(r[5])
            avg_days = float(r[9])
            opy = float(r[10])
            velocity = r[21]

            # Recency score (0-40)
            if days_since <= avg_days:
                recency = 0
            else:
                recency = min(40, (days_since - avg_days) / avg_days * 20)

            # Frequency score (0-30)
            if opy < 1:
                freq = 30
            elif opy < 2:
                freq = 20
            elif opy < 4:
                freq = 10
            else:
                freq = 0

            # Trend score (0-30)
            if velocity == 'Slowing':
                trend = 30
            elif velocity == 'Accelerating':
                trend = 0
            else:
                trend = 15

            exp = min(100, round(recency + freq + trend, 1))
            actual = float(r[22])
            assert abs(actual - exp) < 2.0, f"{r[0]}: churn {actual} != {exp}"


# ============ PHASE 10: REVENUE CONCENTRATION ============

class TestPhase10RevenueConcentration:
    def test_contribution_sums_to_100(self, clv_rows):
        """Verify revenue_contribution_pct values sum to approximately 100%."""
        print("\n" + "="*50 + "\nPHASE 10: Revenue Concentration\n" + "="*50)
        total = sum(float(r[23]) for r in clv_rows)
        assert abs(total - 100) < 1.0, f"Contributions sum to {total}"

    def test_revenue_rank_ordering(self, clv_rows):
        """Revenue rank 1 should have highest revenue."""
        sorted_by_rev = sorted(clv_rows, key=lambda x: float(x[7]), reverse=True)
        for i, r in enumerate(sorted_by_rev):
            # Allow for ties
            if i > 0 and float(r[7]) == float(sorted_by_rev[i-1][7]):
                continue
            exp_rank = i + 1
            assert int(r[25]) <= exp_rank + 1, f"{r[0]}: rank {r[25]} for position {i+1}"

    def test_cumulative_revenue_ordering(self, clv_rows):
        """Cumulative revenue should increase with rank."""
        sorted_by_rank = sorted(clv_rows, key=lambda x: int(x[25]))
        prev_cum = 0
        for r in sorted_by_rank:
            cum = float(r[24])
            assert cum >= prev_cum, f"{r[0]}: cumulative {cum} < {prev_cum}"
            prev_cum = cum

    def test_cumulative_ends_at_100(self, clv_rows):
        """Verify the maximum cumulative_revenue_pct is approximately 100%."""
        max_cum = max(float(r[24]) for r in clv_rows)
        assert abs(max_cum - 100) < 1.0, f"Max cumulative is {max_cum}"


# ============ PHASE 11: ENGAGEMENT SCORE ============

class TestPhase11EngagementScore:
    def test_engagement_range(self, clv_rows):
        """Verify engagement_score is within the 0-100 range for all customers."""
        print("\n" + "="*50 + "\nPHASE 11: Engagement Score\n" + "="*50)
        for r in clv_rows:
            score = float(r[26])
            assert 0 <= score <= 100, f"{r[0]}: engagement {score} out of range"

    def test_engagement_components(self, clv_rows):
        """Verify engagement score has reasonable values based on inputs."""
        for r in clv_rows:
            days_since = int(r[5])
            opy = float(r[10])
            pctl = float(r[16])
            engagement = float(r[26])

            # High frequency + recent + high value should = high engagement
            if opy >= 5 and days_since <= 30 and pctl >= 80:
                assert engagement >= 50, f"{r[0]}: should have high engagement"

            # Low frequency + inactive = low engagement
            if opy < 1 and days_since > 300:
                assert engagement <= 60, f"{r[0]}: should have low engagement"


# ============ PHASE 12: EXPECTED NEXT ORDER ============

class TestPhase12ExpectedNextOrder:
    def test_expected_date_logic(self, clv_rows):
        """Verify expected_next_order_date equals last_order_date + avg_days_between_orders."""
        print("\n" + "="*50 + "\nPHASE 12: Expected Next Order\n" + "="*50)
        for r in clv_rows:
            last_date = r[3].date() if hasattr(r[3], 'date') else r[3]
            avg_days = float(r[9])
            expected_date = r[27]

            if hasattr(expected_date, 'date'):
                expected_date = expected_date.date()

            # Expected = last + avg_days (rounded)
            from datetime import timedelta
            exp_date = last_date + timedelta(days=round(avg_days))
            diff = abs((expected_date - exp_date).days)
            assert diff <= 1, f"{r[0]}: expected date off by {diff} days"

    def test_days_until_calculation(self, clv_rows):
        """Verify days_until_expected_order equals expected_next_order_date minus reference date."""
        for r in clv_rows:
            expected_date = r[27]
            if hasattr(expected_date, 'date'):
                expected_date = expected_date.date()

            days_until = int(r[28])
            exp = (expected_date - REFERENCE_DATE).days
            assert abs(days_until - exp) <= 1, f"{r[0]}: days until {days_until} != {exp}"

    def test_days_overdue(self, clv_rows):
        """Verify days_overdue is 0 when not overdue, or negative of days_until when overdue."""
        for r in clv_rows:
            days_until = int(r[28])
            days_overdue = int(r[29])

            if days_until >= 0:
                assert days_overdue == 0, f"{r[0]}: not overdue but overdue={days_overdue}"
            else:
                assert days_overdue == -days_until, f"{r[0]}: overdue {days_overdue} != {-days_until}"


# ============ PHASE 13: LIFECYCLE ============

class TestPhase13Lifecycle:
    def test_valid_stages(self, clv_rows):
        """Verify all lifecycle_stage values are in the allowed set."""
        print("\n" + "="*50 + "\nPHASE 13: Lifecycle\n" + "="*50)
        for r in clv_rows:
            assert r[18] in VALID_LIFECYCLE_STAGES, f"Invalid: {r[18]}"

    def test_lifecycle_logic(self, clv_rows):
        """Verify lifecycle_stage follows priority-based classification logic."""
        for r in clv_rows:
            tenure = int(r[4])
            days_since = int(r[5])
            orders = int(r[6])
            opy = float(r[10])
            segment = r[14]
            at_risk = is_truthy(r[15])
            stage = r[18]
            trajectory = r[20]

            # Check against the defined logic (first match wins)
            if orders == 2 and tenure <= 90:
                assert stage == 'New', f"{r[0]}: expected New, got {stage}"
            elif orders >= 3 and opy > 4 and not at_risk and trajectory != 'Decelerating':
                assert stage == 'Growing', f"{r[0]}: expected Growing, got {stage}"
            elif orders >= 3 and opy <= 4 and not at_risk and trajectory != 'Decelerating':
                assert stage == 'Mature', f"{r[0]}: expected Mature, got {stage}"
            elif at_risk and days_since <= 365 and segment in ('Platinum', 'Gold'):
                assert stage == 'At Risk - High Value', f"{r[0]}: expected At Risk - High Value, got {stage}"
            elif at_risk and days_since <= 365:
                assert stage == 'Declining', f"{r[0]}: expected Declining, got {stage}"
            elif days_since > 365:
                assert stage == 'Churned', f"{r[0]}: expected Churned, got {stage}"


# ============ PHASE 14: QUARTER FORMAT ============

class TestPhase14Quarter:
    def test_quarter_format(self, clv_rows):
        """Verify first_order_quarter follows YYYY-QN format."""
        print("\n" + "="*50 + "\nPHASE 14: Quarter\n" + "="*50)
        for r in clv_rows:
            assert re.match(r'^\d{4}-Q[1-4]$', r[19]), f"Bad format: {r[19]}"

    def test_quarter_accuracy(self, clv_rows):
        """Verify first_order_quarter matches the quarter derived from first_order_date."""
        for r in clv_rows:
            first = r[2].date() if hasattr(r[2], 'date') else r[2]
            exp = get_quarter(first)
            assert r[19] == exp, f"{r[0]}: {r[19]} != {exp}"


# ============ PHASE 15: SEGMENT SUMMARY ============

class TestPhase15Summary:
    def test_summary_exists(self, summary_rows):
        """Verify clv_segment_summary model contains data."""
        print("\n" + "="*50 + "\nPHASE 15: Summary\n" + "="*50)
        assert len(summary_rows) > 0

    def test_all_segments(self, summary_rows, clv_rows):
        """Verify all segments from clv_segments appear in the summary."""
        clv_segs = set(r[14] for r in clv_rows)
        sum_segs = set(r[0] for r in summary_rows)
        assert clv_segs == sum_segs

    def test_customer_count(self, summary_rows, clv_rows):
        """Verify customer_count per segment matches actual count from clv_segments."""
        counts = Counter(r[14] for r in clv_rows)
        for r in summary_rows:
            assert int(r[1]) == counts[r[0]]

    def test_avg_npv(self, summary_rows, clv_rows):
        """Verify avg NPV calculation."""
        by_seg = {}
        for r in clv_rows:
            by_seg.setdefault(r[14], []).append(float(r[13]))
        for r in summary_rows:
            if r[0] in by_seg:
                exp = round(mean(by_seg[r[0]]), 2)
                assert abs(float(r[4]) - exp) < 1.0, f"{r[0]}: avg NPV"

    def test_churned_count(self, summary_rows, clv_rows):
        """Verify churned_count per segment matches actual Churned lifecycle count."""
        by_seg = {}
        for r in clv_rows:
            if r[18] == 'Churned':
                by_seg[r[14]] = by_seg.get(r[14], 0) + 1
        for r in summary_rows:
            exp = by_seg.get(r[0], 0)
            assert int(r[8]) == exp, f"{r[0]}: churned {r[8]} != {exp}"

    def test_accelerating_count(self, summary_rows, clv_rows):
        """Verify accelerating_count per segment matches actual Accelerating trajectory count."""
        by_seg = {}
        for r in clv_rows:
            if r[20] == 'Accelerating':
                by_seg[r[14]] = by_seg.get(r[14], 0) + 1
        for r in summary_rows:
            exp = by_seg.get(r[0], 0)
            assert int(r[12]) == exp, f"{r[0]}: accelerating {r[12]} != {exp}"

    def test_decelerating_count(self, summary_rows, clv_rows):
        """Verify decelerating_count per segment matches actual Decelerating trajectory count."""
        by_seg = {}
        for r in clv_rows:
            if r[20] == 'Decelerating':
                by_seg[r[14]] = by_seg.get(r[14], 0) + 1
        for r in summary_rows:
            exp = by_seg.get(r[0], 0)
            assert int(r[13]) == exp, f"{r[0]}: decelerating {r[13]} != {exp}"

    def test_pct_revenue_contribution(self, summary_rows, clv_rows):
        """Verify pct_revenue_contribution per segment matches calculated share of total revenue."""
        total_rev = sum(float(r[7]) for r in clv_rows)
        by_seg = {}
        for r in clv_rows:
            by_seg[r[14]] = by_seg.get(r[14], 0) + float(r[7])
        for r in summary_rows:
            exp = round(100 * by_seg.get(r[0], 0) / total_rev, 1)
            assert abs(float(r[14]) - exp) < 0.5, f"{r[0]}: pct rev {r[14]} != {exp}"

    def test_ordering(self, summary_rows):
        """Verify summary rows are ordered by avg_clv_3_year descending."""
        clvs = [float(r[3]) for r in summary_rows]
        assert clvs == sorted(clvs, reverse=True)


# ============ PHASE 16: COHORT ANALYSIS ============

class TestPhase16Cohort:
    def test_cohort_exists(self, cohort_rows):
        """Verify clv_cohort_analysis model contains data."""
        print("\n" + "="*50 + "\nPHASE 16: Cohort\n" + "="*50)
        assert len(cohort_rows) > 0

    def test_cohort_format(self, cohort_rows):
        """Verify cohort_quarter follows YYYY-QN format."""
        for r in cohort_rows:
            assert re.match(r'^\d{4}-Q[1-4]$', r[0]), f"Bad: {r[0]}"

    def test_cohort_ordering(self, cohort_rows):
        """Verify cohort rows are ordered by cohort_quarter ascending."""
        quarters = [r[0] for r in cohort_rows]
        assert quarters == sorted(quarters)

    def test_cohort_size(self, cohort_rows, clv_rows):
        """Verify cohort_size matches the count of customers per quarter from clv_segments."""
        by_cohort = Counter(r[19] for r in clv_rows)
        for r in cohort_rows:
            assert int(r[1]) == by_cohort[r[0]], f"{r[0]}: size {r[1]} != {by_cohort[r[0]]}"

    def test_segment_counts(self, cohort_rows, clv_rows):
        """Verify per-cohort Platinum/Gold/Silver/Bronze counts match clv_segments data."""
        by_cohort = {}
        for r in clv_rows:
            coh = r[19]
            seg = r[14]
            if coh not in by_cohort:
                by_cohort[coh] = {'Platinum': 0, 'Gold': 0, 'Silver': 0, 'Bronze': 0}
            by_cohort[coh][seg] += 1

        for r in cohort_rows:
            coh = r[0]
            if coh in by_cohort:
                assert int(r[10]) == by_cohort[coh]['Platinum'], f"{coh}: plat"
                assert int(r[11]) == by_cohort[coh]['Gold'], f"{coh}: gold"
                assert int(r[12]) == by_cohort[coh]['Silver'], f"{coh}: silver"
                assert int(r[13]) == by_cohort[coh]['Bronze'], f"{coh}: bronze"

    def test_retention_rate(self, cohort_rows, clv_rows):
        """Verify retention_rate equals (total - churned) / total per cohort."""
        by_cohort = {}
        for r in clv_rows:
            coh = r[19]
            churned = r[18] == 'Churned'
            if coh not in by_cohort:
                by_cohort[coh] = {'total': 0, 'churned': 0}
            by_cohort[coh]['total'] += 1
            if churned:
                by_cohort[coh]['churned'] += 1

        for r in cohort_rows:
            coh = r[0]
            if coh in by_cohort:
                total = by_cohort[coh]['total']
                churned = by_cohort[coh]['churned']
                exp = round(100.0 * (total - churned) / total, 1)
                assert abs(float(r[6]) - exp) < 0.2, f"{coh}: retention {r[6]} != {exp}"

    def test_accelerating_pct(self, cohort_rows, clv_rows):
        """Verify accelerating_pct matches calculated percentage of Accelerating customers per cohort."""
        by_cohort = {}
        for r in clv_rows:
            coh = r[19]
            if coh not in by_cohort:
                by_cohort[coh] = {'total': 0, 'acc': 0}
            by_cohort[coh]['total'] += 1
            if r[20] == 'Accelerating':
                by_cohort[coh]['acc'] += 1

        for r in cohort_rows:
            coh = r[0]
            if coh in by_cohort:
                total = by_cohort[coh]['total']
                acc = by_cohort[coh]['acc']
                exp = round(100.0 * acc / total, 1)
                assert abs(float(r[14]) - exp) < 0.5, f"{coh}: acc% {r[14]} != {exp}"


# ============ PHASE 17: MONTHLY TRENDS ============

class TestPhase17MonthlyTrends:
    def test_monthly_exists(self, monthly_rows):
        """Verify clv_monthly_trends model contains data."""
        print("\n" + "="*50 + "\nPHASE 17: Monthly Trends\n" + "="*50)
        assert len(monthly_rows) > 0

    def test_month_format(self, monthly_rows):
        """Verify order_month follows YYYY-MM format."""
        for r in monthly_rows:
            assert re.match(r'^\d{4}-\d{2}$', r[1]), f"Bad month format: {r[1]}"

    def test_monthly_ordering(self, monthly_rows):
        """Verify monthly trend rows are sorted by order_month within each customer."""
        by_cust = {}
        for r in monthly_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, rows in by_cust.items():
            months = [r[1] for r in rows]
            assert months == sorted(months), f"{cid}: months not sorted"

    def test_cumulative_orders(self, monthly_rows):
        """Verify cumulative orders increases."""
        by_cust = {}
        for r in monthly_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, rows in by_cust.items():
            prev_cum = 0
            for r in rows:
                assert int(r[4]) >= prev_cum, f"{cid}: cumulative orders decreased"
                assert int(r[4]) >= int(r[2]), f"{cid}: cumulative < monthly"
                prev_cum = int(r[4])

    def test_cumulative_revenue(self, monthly_rows):
        """Verify cumulative revenue increases."""
        by_cust = {}
        for r in monthly_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, rows in by_cust.items():
            prev_cum = 0
            for r in rows:
                cum = float(r[5])
                assert cum >= prev_cum, f"{cid}: cumulative revenue decreased"
                prev_cum = cum

    def test_month_rank(self, monthly_rows):
        """Verify month rank starts at 1 and increases."""
        by_cust = {}
        for r in monthly_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, rows in by_cust.items():
            for i, r in enumerate(rows):
                assert int(r[9]) == i + 1, f"{cid}: rank {r[9]} != {i+1}"

    def test_months_since_first(self, monthly_rows):
        """Verify months_since_first_order is 0 for first month."""
        by_cust = {}
        for r in monthly_rows:
            by_cust.setdefault(r[0], []).append(r)
        for cid, rows in by_cust.items():
            assert int(rows[0][6]) == 0, f"{cid}: first month should be 0"


# ============ PHASE 18: MATERIALIZATION ============

class TestPhase18Materialization:
    def test_clv_segments_table(self, schema_name):
        """Verify clv_segments is materialized as a table, not a view."""
        print("\n" + "="*50 + "\nPHASE 18: Materialization\n" + "="*50)
        t = get_table_type(schema_name, "clv_segments")
        assert t and t.upper() in ("BASE TABLE", "TABLE")

    def test_summary_table(self, schema_name):
        """Verify clv_segment_summary is materialized as a table."""
        t = get_table_type(schema_name, "clv_segment_summary")
        assert t and t.upper() in ("BASE TABLE", "TABLE")

    def test_cohort_table(self, schema_name):
        """Verify clv_cohort_analysis is materialized as a table."""
        t = get_table_type(schema_name, "clv_cohort_analysis")
        assert t and t.upper() in ("BASE TABLE", "TABLE")

    def test_monthly_table(self, schema_name):
        """Verify clv_monthly_trends is materialized as a table."""
        t = get_table_type(schema_name, "clv_monthly_trends")
        assert t and t.upper() in ("BASE TABLE", "TABLE")


# ============ PHASE 19: IDEMPOTENCY ============

class TestPhase19Idempotency:
    def test_idempotency(self, clv_rows):
        """Verify re-running the dbt pipeline produces identical results."""
        print("\n" + "="*50 + "\nPHASE 19: Idempotency\n" + "="*50)
        before = list(clv_rows)
        run_dbt_pipeline()
        after = query_clv_segments()
        assert len(before) == len(after)
        for row_b, row_a in zip(before, after):
            if row_b != row_a:
                for i, (b, a) in enumerate(zip(row_b, row_a)):
                    if b == a:
                        continue
                    try:
                        if abs(float(b) - float(a)) < 0.01:
                            continue
                    except (TypeError, ValueError):
                        pass
                    assert False, \
                        f"Row changed after re-run:\nBefore: {row_b}\nAfter: {row_a}"
