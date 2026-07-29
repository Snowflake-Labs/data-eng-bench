"""
Test verifier for RFM Customer Segmentation with Predictive Analytics.
Multi-phase testing:
  Phase 1: Validate rfm_segments model structure and columns
  Phase 2: Validate rfm_segments calculations (scores, segments, churn, LTV)
  Phase 3: Validate rpt_segment_summary model
  Phase 4: Validate rpt_customer_recommendations model
  Phase 5: Validate rfm_cohort_retention model
  Phase 6: Cross-model consistency checks
  Phase 7: Idempotency test
"""
import subprocess
import pytest
import os
from collections import Counter


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


def _get_model_schema():
    """Get model schema based on DB_TYPE.
    DuckDB: main_rfm_analytics (dbt default prefixing)
    Snowflake: main (generate_schema_name override)
    """
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'main_rfm_analytics'


# Schema where models are created
MODEL_SCHEMA = _get_model_schema()


VALID_SEGMENTS = ['Champions', 'Loyal', 'Potential', 'At Risk', 'Lost']
VALID_QUARTERLY_TRENDS = ['accelerating', 'decelerating', 'stable', 'churning']
VALID_RISK_LEVELS = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']
VALID_INTERVENTION_TYPES = ['immediate_outreach', 'win_back_campaign', 'engagement_program', 'loyalty_program']

VALID_RECOMMENDATIONS = {
    ('Champions', 'CRITICAL'): 'Executive outreach with exclusive preview access',
    ('Champions', 'HIGH'): 'Executive outreach with exclusive preview access',
    ('Champions', 'MEDIUM'): 'VIP early access and personalized recommendations',
    ('Champions', 'LOW'): 'VIP early access and personalized recommendations',
    ('Loyal', 'CRITICAL'): 'Personal account manager contact with special offer',
    ('Loyal', 'HIGH'): 'Personal account manager contact with special offer',
    ('Loyal', 'MEDIUM'): 'Loyalty program upgrade with bonus points',
    ('Loyal', 'LOW'): 'Loyalty program upgrade with bonus points',
    ('Potential', 'CRITICAL'): 'Targeted email series with progressive discounts',
    ('Potential', 'HIGH'): 'Targeted email series with progressive discounts',
    ('Potential', 'MEDIUM'): 'Targeted email series with progressive discounts',
    ('Potential', 'LOW'): 'Targeted email series with progressive discounts',
    ('At Risk', 'CRITICAL'): 'Urgent win-back: 30% off next purchase within 7 days',
    ('At Risk', 'HIGH'): 'Urgent win-back: 30% off next purchase within 7 days',
    ('At Risk', 'MEDIUM'): 'Urgent win-back: 30% off next purchase within 7 days',
    ('At Risk', 'LOW'): 'Urgent win-back: 30% off next purchase within 7 days',
    ('Lost', 'CRITICAL'): 'Final reactivation: 50% off or account closure notice',
    ('Lost', 'HIGH'): 'Final reactivation: 50% off or account closure notice',
    ('Lost', 'MEDIUM'): 'Final reactivation: 50% off or account closure notice',
    ('Lost', 'LOW'): 'Final reactivation: 50% off or account closure notice',
}


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
    """Run dbt deps and dbt run for RFM models."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    result = run_cmd("dbt run --select rfm_segments rpt_segment_summary rpt_customer_recommendations rfm_cohort_retention")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_rfm_segments():
    """Query rfm_segments model with all columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id, first_order_date, last_order_date, customer_tenure_days,
                recency_days, recency_score, recency_percentile,
                total_orders, frequency_score, frequency_percentile,
                total_spent, monetary_score, monetary_percentile,
                avg_order_value, avg_days_between_orders,
                orders_q4_2024, orders_q3_2024, orders_q2_2024, orders_q1_2024,
                quarterly_trend, spending_velocity,
                rfm_score, rfm_segment, churn_probability, lifetime_value_estimate
            FROM {MODEL_SCHEMA}.rfm_segments
            ORDER BY customer_id
        """)
        return rows
    finally:
        conn.close()


def query_segment_summary():
    """Query rpt_segment_summary model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                rfm_segment, customer_count, pct_of_total, total_revenue,
                avg_revenue_per_customer, avg_churn_probability,
                total_lifetime_value, avg_lifetime_value,
                churning_customers, accelerating_customers
            FROM {MODEL_SCHEMA}.rpt_segment_summary
            ORDER BY customer_count DESC
        """)
        return rows
    finally:
        conn.close()


def query_recommendations():
    """Query rpt_customer_recommendations model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id, rfm_segment, rfm_score, quarterly_trend, churn_probability,
                risk_level, intervention_type, recommended_action,
                estimated_value, urgency_days, priority_score
            FROM {MODEL_SCHEMA}.rpt_customer_recommendations
            ORDER BY priority_score DESC, customer_id ASC
        """)
        return rows
    finally:
        conn.close()


def query_cohort_retention():
    """Query rfm_cohort_retention model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                cohort_month, months_since_first, cohort_size,
                retained_customers, retention_rate,
                cohort_revenue, avg_order_value
            FROM {MODEL_SCHEMA}.rfm_cohort_retention
            ORDER BY cohort_month ASC, months_since_first ASC
        """)
        return rows
    finally:
        conn.close()


def get_expected_customer_count():
    """Get expected customer count from source."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT CUSTOMER_ID)
            FROM ORDERS.ORDERS
            WHERE STATUS NOT IN ('CANCELLED', 'RETURNED')
              AND CUSTOMER_ID IS NOT NULL
        """)
        return int(result)
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def rfm_rows(dbt_run):
    """Fixture that provides rfm_segments rows after dbt run."""
    return query_rfm_segments()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    """Fixture that provides rpt_segment_summary rows after dbt run."""
    return query_segment_summary()


@pytest.fixture(scope="module")
def recommendation_rows(dbt_run):
    """Fixture that provides rpt_customer_recommendations rows after dbt run."""
    return query_recommendations()


@pytest.fixture(scope="module")
def cohort_rows(dbt_run):
    """Fixture that provides rfm_cohort_retention rows after dbt run."""
    return query_cohort_retention()


@pytest.fixture(scope="module")
def expected_customer_count():
    """Fixture that provides expected customer count."""
    return get_expected_customer_count()


# ============ PHASE 1: rfm_segments Structure ============

class TestPhase1RfmSegmentsStructure:
    """Phase 1: Validate rfm_segments model structure and required columns."""

    def test_model_file_exists(self, dbt_run):
        """Validate the model file exists at the expected location."""
        dbt_dir = get_dbt_project_dir()
        model_path = os.path.join(dbt_dir, "models/marts/rfm/rfm_segments.sql")
        assert os.path.exists(model_path), \
            f"Model file not found at {model_path}. Create the model in models/marts/rfm/"

    def test_model_exists_in_schema(self, dbt_run):
        """Validate rfm_segments model was created in correct schema."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rfm_segments'
            """)
            assert int(result) > 0, f"Model rfm_segments not found in schema {MODEL_SCHEMA}"
        finally:
            conn.close()

    def test_all_required_columns(self, dbt_run):
        """Validate all 25 required columns exist in rfm_segments."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rfm_segments'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                'customer_id', 'first_order_date', 'last_order_date', 'customer_tenure_days',
                'recency_days', 'recency_score', 'recency_percentile',
                'total_orders', 'frequency_score', 'frequency_percentile',
                'total_spent', 'monetary_score', 'monetary_percentile',
                'avg_order_value', 'avg_days_between_orders',
                'orders_q4_2024', 'orders_q3_2024', 'orders_q2_2024', 'orders_q1_2024',
                'quarterly_trend', 'spending_velocity',
                'rfm_score', 'rfm_segment', 'churn_probability', 'lifetime_value_estimate'
            }
            missing = required - col_names
            assert not missing, f"Missing columns in rfm_segments: {missing}"
        finally:
            conn.close()

    def test_has_customers(self, rfm_rows):
        """Validate model has customer data."""
        assert len(rfm_rows) > 0, "rfm_segments has no rows"

    def test_customer_count_matches(self, rfm_rows, expected_customer_count):
        """Validate customer count matches source data."""
        actual_count = len(rfm_rows)
        assert actual_count == expected_customer_count, \
            f"Customer count mismatch: model has {actual_count}, expected {expected_customer_count}"


# ============ PHASE 2: rfm_segments Calculations ============

class TestPhase2RfmSegmentsCalculations:
    """Phase 2: Validate rfm_segments calculations and logic."""

    def test_scores_in_valid_range(self, rfm_rows):
        """Validate RFM scores are 1-5."""
        for row in rfm_rows:
            r_score, f_score, m_score = int(row[5]), int(row[8]), int(row[11])
            assert 1 <= r_score <= 5, f"Invalid recency_score {r_score} for customer {row[0]}"
            assert 1 <= f_score <= 5, f"Invalid frequency_score {f_score} for customer {row[0]}"
            assert 1 <= m_score <= 5, f"Invalid monetary_score {m_score} for customer {row[0]}"

    def test_percentiles_in_valid_range(self, rfm_rows):
        """Validate percentiles are between 0 and 100."""
        for row in rfm_rows:
            r_pct, f_pct, m_pct = float(row[6]), float(row[9]), float(row[12])
            assert 0 <= r_pct <= 100, f"Invalid recency_percentile {r_pct}"
            assert 0 <= f_pct <= 100, f"Invalid frequency_percentile {f_pct}"
            assert 0 <= m_pct <= 100, f"Invalid monetary_percentile {m_pct}"

    def test_rfm_score_calculation(self, rfm_rows):
        """Validate rfm_score = recency_score + frequency_score + monetary_score."""
        for row in rfm_rows:
            r_score, f_score, m_score = int(row[5]), int(row[8]), int(row[11])
            rfm_score = int(row[21])
            expected = r_score + f_score + m_score
            assert rfm_score == expected, \
                f"rfm_score mismatch for {row[0]}: got {rfm_score}, expected {expected}"

    def test_rfm_score_range(self, rfm_rows):
        """Validate rfm_score is between 3 and 15."""
        for row in rfm_rows:
            rfm_score = int(row[21])
            assert 3 <= rfm_score <= 15, f"Invalid rfm_score {rfm_score} for customer {row[0]}"

    def test_segment_assignment_logic(self, rfm_rows):
        """Validate segment assignment based on average score."""
        for row in rfm_rows:
            r_score, f_score, m_score = int(row[5]), int(row[8]), int(row[11])
            segment = row[22]
            avg = (r_score + f_score + m_score) / 3.0

            if avg >= 4.5:
                expected = 'Champions'
            elif avg >= 3.5:
                expected = 'Loyal'
            elif avg >= 2.5:
                expected = 'Potential'
            elif avg >= 1.5:
                expected = 'At Risk'
            else:
                expected = 'Lost'

            assert segment == expected, \
                f"Customer {row[0]}: avg={avg:.2f}, expected '{expected}', got '{segment}'"

    def test_valid_segments(self, rfm_rows):
        """Validate all segments are valid."""
        for row in rfm_rows:
            segment = row[22]
            assert segment in VALID_SEGMENTS, f"Invalid segment '{segment}' for customer {row[0]}"

    def test_valid_quarterly_trends(self, rfm_rows):
        """Validate all quarterly_trend values are valid."""
        for row in rfm_rows:
            trend = row[19]
            assert trend in VALID_QUARTERLY_TRENDS, f"Invalid quarterly_trend '{trend}' for customer {row[0]}"

    def test_quarterly_trend_logic(self, rfm_rows):
        """Validate quarterly_trend calculation logic."""
        for row in rfm_rows:
            q4 = int(row[15])
            q3 = int(row[16])
            q2 = int(row[17])
            trend = row[19]

            if q4 > q3 and q3 >= q2:
                expected = 'accelerating'
            elif q4 < q3 and q3 <= q2:
                expected = 'decelerating'
            elif q4 == 0 and q3 > 0:
                expected = 'churning'
            else:
                expected = 'stable'

            assert trend == expected, \
                f"Customer {row[0]}: q4={q4}, q3={q3}, q2={q2}, expected '{expected}', got '{trend}'"

    def test_churn_probability_range(self, rfm_rows):
        """Validate churn_probability is between 0 and 100."""
        for row in rfm_rows:
            churn = int(row[23])
            assert 0 <= churn <= 100, f"Invalid churn_probability {churn} for customer {row[0]}"

    def test_churn_probability_formula(self, rfm_rows):
        """Validate churn_probability calculation formula."""
        for row in rfm_rows:
            r_score, f_score, m_score = int(row[5]), int(row[8]), int(row[11])
            trend = row[19]
            churn = int(row[23])

            base_risk = (5 - r_score) * 15 + (5 - f_score) * 10 + (5 - m_score) * 5
            trend_modifier = {
                'churning': 30,
                'decelerating': 15,
                'stable': 0,
                'accelerating': -10
            }[trend]
            expected = max(0, min(100, base_risk + trend_modifier))

            assert churn == expected, \
                f"Customer {row[0]}: churn_probability mismatch, got {churn}, expected {expected}"

    def test_lifetime_value_non_negative(self, rfm_rows):
        """Validate lifetime_value_estimate is non-negative."""
        for row in rfm_rows:
            ltv = float(row[24])
            assert ltv >= 0, f"Negative lifetime_value_estimate {ltv} for customer {row[0]}"

    def test_lifetime_value_formula(self, rfm_rows):
        """Validate lifetime_value_estimate calculation formula."""
        for row in rfm_rows:
            tenure_days = int(row[3])
            total_spent = float(row[10])
            segment = row[22]
            churn = int(row[23])
            ltv = float(row[24])

            if tenure_days == 0:
                expected = 0.0
            else:
                months_as_customer = tenure_days / 30.0
                monthly_value = total_spent / months_as_customer
                remaining_months = {
                    'Champions': 36,
                    'Loyal': 24,
                    'Potential': 12,
                    'At Risk': 6,
                    'Lost': 0
                }[segment]
                retention_factor = (100 - churn) / 100.0
                # Use max(0, ...) to ensure non-negative
                expected = max(0, round(monthly_value * remaining_months * retention_factor, 2))

            assert abs(ltv - expected) < 0.02, \
                f"Customer {row[0]}: LTV mismatch, got {ltv}, expected {expected}"

    def test_avg_order_value_calculation(self, rfm_rows):
        """Validate avg_order_value = total_spent / total_orders."""
        for row in rfm_rows:
            total_orders = int(row[7])
            total_spent = float(row[10])
            avg_order_value = float(row[13])
            expected = round(total_spent / total_orders, 2) if total_orders > 0 else 0
            assert abs(avg_order_value - expected) < 0.01, \
                f"avg_order_value mismatch for {row[0]}: got {avg_order_value}, expected {expected:.2f}"

    def test_no_null_critical_values(self, rfm_rows):
        """Validate no NULL values in critical columns."""
        for row in rfm_rows:
            assert row[0] is not None, "NULL customer_id found"
            assert row[5] is not None, "NULL recency_score found"
            assert row[8] is not None, "NULL frequency_score found"
            assert row[11] is not None, "NULL monetary_score found"
            assert row[21] is not None, "NULL rfm_score found"
            assert row[22] is not None, "NULL rfm_segment found"
            assert row[23] is not None, "NULL churn_probability found"
            assert row[24] is not None, "NULL lifetime_value_estimate found"


# ============ PHASE 3: rpt_segment_summary ============

class TestPhase3SegmentSummary:
    """Phase 3: Validate rpt_segment_summary model."""

    def test_model_file_exists(self, dbt_run):
        """Validate the model file exists at the expected location."""
        dbt_dir = get_dbt_project_dir()
        model_path = os.path.join(dbt_dir, "models/marts/rfm/rpt_segment_summary.sql")
        assert os.path.exists(model_path), \
            f"Model file not found at {model_path}"

    def test_model_exists_in_schema(self, dbt_run):
        """Validate rpt_segment_summary model was created."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rpt_segment_summary'
            """)
            assert int(result) > 0, f"Model rpt_segment_summary not found in schema {MODEL_SCHEMA}"
        finally:
            conn.close()

    def test_all_required_columns(self, dbt_run):
        """Validate all required columns exist in rpt_segment_summary."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rpt_segment_summary'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                'rfm_segment', 'customer_count', 'pct_of_total', 'total_revenue',
                'avg_revenue_per_customer', 'avg_churn_probability',
                'total_lifetime_value', 'avg_lifetime_value',
                'churning_customers', 'accelerating_customers'
            }
            missing = required - col_names
            assert not missing, f"Missing columns in rpt_segment_summary: {missing}"
        finally:
            conn.close()

    def test_has_all_segments(self, summary_rows, rfm_rows):
        """Validate summary has all segments that exist in rfm_segments."""
        rfm_segments = set(row[22] for row in rfm_rows)
        summary_segments = set(row[0] for row in summary_rows)
        assert rfm_segments == summary_segments, \
            f"Segment mismatch: rfm has {rfm_segments}, summary has {summary_segments}"

    def test_customer_count_matches(self, summary_rows, rfm_rows):
        """Validate sum of customer_count equals total customers."""
        total_from_summary = sum(int(row[1]) for row in summary_rows)
        assert total_from_summary == len(rfm_rows), \
            f"Customer count mismatch: summary has {total_from_summary}, rfm has {len(rfm_rows)}"

    def test_pct_of_total_sums_to_100(self, summary_rows):
        """Validate pct_of_total sums to approximately 100."""
        total_pct = sum(float(row[2]) for row in summary_rows)
        assert abs(total_pct - 100.0) < 0.1, \
            f"pct_of_total should sum to 100, got {total_pct}"

    def test_churning_customers_count(self, summary_rows, rfm_rows):
        """Validate churning_customers counts match rfm_segments."""
        churning_by_segment = Counter()
        for row in rfm_rows:
            segment = row[22]
            trend = row[19]
            if trend == 'churning':
                churning_by_segment[segment] += 1

        for summary_row in summary_rows:
            segment = summary_row[0]
            churning_count = int(summary_row[8])
            expected = churning_by_segment.get(segment, 0)
            assert churning_count == expected, \
                f"churning_customers mismatch for {segment}: got {churning_count}, expected {expected}"

    def test_accelerating_customers_count(self, summary_rows, rfm_rows):
        """Validate accelerating_customers counts match rfm_segments."""
        accelerating_by_segment = Counter()
        for row in rfm_rows:
            segment = row[22]
            trend = row[19]
            if trend == 'accelerating':
                accelerating_by_segment[segment] += 1

        for summary_row in summary_rows:
            segment = summary_row[0]
            accel_count = int(summary_row[9])
            expected = accelerating_by_segment.get(segment, 0)
            assert accel_count == expected, \
                f"accelerating_customers mismatch for {segment}: got {accel_count}, expected {expected}"

    def test_ordered_by_customer_count_desc(self, summary_rows):
        """Validate results are ordered by customer_count descending."""
        counts = [int(row[1]) for row in summary_rows]
        assert counts == sorted(counts, reverse=True), \
            "rpt_segment_summary should be ordered by customer_count DESC"


# ============ PHASE 4: rpt_customer_recommendations ============

class TestPhase4Recommendations:
    """Phase 4: Validate rpt_customer_recommendations model."""

    def test_model_file_exists(self, dbt_run):
        """Validate the model file exists at the expected location."""
        dbt_dir = get_dbt_project_dir()
        model_path = os.path.join(dbt_dir, "models/marts/rfm/rpt_customer_recommendations.sql")
        assert os.path.exists(model_path), \
            f"Model file not found at {model_path}"

    def test_model_exists_in_schema(self, dbt_run):
        """Validate rpt_customer_recommendations model was created."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rpt_customer_recommendations'
            """)
            assert int(result) > 0, f"Model rpt_customer_recommendations not found in schema {MODEL_SCHEMA}"
        finally:
            conn.close()

    def test_all_required_columns(self, dbt_run):
        """Validate all required columns exist in rpt_customer_recommendations."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rpt_customer_recommendations'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                'customer_id', 'rfm_segment', 'rfm_score', 'quarterly_trend', 'churn_probability',
                'risk_level', 'intervention_type', 'recommended_action',
                'estimated_value', 'urgency_days', 'priority_score'
            }
            missing = required - col_names
            assert not missing, f"Missing columns in rpt_customer_recommendations: {missing}"
        finally:
            conn.close()

    def test_customer_count_matches(self, recommendation_rows, rfm_rows):
        """Validate recommendation count matches rfm_segments count."""
        assert len(recommendation_rows) == len(rfm_rows), \
            f"Row count mismatch: recommendations has {len(recommendation_rows)}, rfm has {len(rfm_rows)}"

    def test_valid_risk_levels(self, recommendation_rows):
        """Validate all risk_level values are valid."""
        for row in recommendation_rows:
            risk = row[5]
            assert risk in VALID_RISK_LEVELS, f"Invalid risk_level '{risk}' for customer {row[0]}"

    def test_valid_intervention_types(self, recommendation_rows):
        """Validate all intervention_type values are valid."""
        for row in recommendation_rows:
            intervention = row[6]
            assert intervention in VALID_INTERVENTION_TYPES, \
                f"Invalid intervention_type '{intervention}' for customer {row[0]}"

    def test_risk_level_logic(self, recommendation_rows):
        """Validate risk_level assignment logic."""
        for row in recommendation_rows:
            segment = row[1]
            trend = row[3]
            churn = int(row[4])
            risk = row[5]

            if churn >= 80:
                expected = 'CRITICAL'
            elif trend == 'churning' and segment in ('Loyal', 'Champions'):
                expected = 'CRITICAL'
            elif churn >= 60:
                expected = 'HIGH'
            elif trend == 'churning':
                expected = 'HIGH'
            elif churn >= 40:
                expected = 'MEDIUM'
            elif trend == 'decelerating':
                expected = 'MEDIUM'
            else:
                expected = 'LOW'

            assert risk == expected, \
                f"Customer {row[0]}: segment={segment}, trend={trend}, churn={churn}, expected risk='{expected}', got '{risk}'"

    def test_intervention_type_logic(self, recommendation_rows):
        """Validate intervention_type assignment logic."""
        for row in recommendation_rows:
            risk = row[5]
            intervention = row[6]

            expected_map = {
                'CRITICAL': 'immediate_outreach',
                'HIGH': 'win_back_campaign',
                'MEDIUM': 'engagement_program',
                'LOW': 'loyalty_program'
            }
            expected = expected_map[risk]

            assert intervention == expected, \
                f"Customer {row[0]}: risk={risk}, expected intervention='{expected}', got '{intervention}'"

    def test_recommended_action_logic(self, recommendation_rows):
        """Validate recommended_action based on segment and risk level."""
        for row in recommendation_rows:
            segment = row[1]
            risk = row[5]
            action = row[7]

            expected = VALID_RECOMMENDATIONS.get((segment, risk))
            assert action == expected, \
                f"Customer {row[0]}: segment={segment}, risk={risk}, expected action='{expected}', got '{action}'"

    def test_urgency_days_logic(self, recommendation_rows):
        """Validate urgency_days assignment logic."""
        for row in recommendation_rows:
            risk = row[5]
            urgency = int(row[9])

            expected_map = {
                'CRITICAL': 3,
                'HIGH': 7,
                'MEDIUM': 14,
                'LOW': 30
            }
            expected = expected_map[risk]

            assert urgency == expected, \
                f"Customer {row[0]}: risk={risk}, expected urgency={expected}, got {urgency}"

    def test_priority_score_calculation(self, recommendation_rows):
        """Validate priority_score calculation."""
        for row in recommendation_rows:
            rfm_score = int(row[2])
            churn = int(row[4])
            risk = row[5]
            segment = row[1]
            priority = float(row[10])

            urgency_modifier = {'CRITICAL': 100, 'HIGH': 50, 'MEDIUM': 25, 'LOW': 0}[risk]
            segment_value = {
                'Champions': 50,
                'Loyal': 40,
                'Potential': 30,
                'At Risk': 20,
                'Lost': 10
            }[segment]
            expected = round((churn * 2) + (rfm_score * 5) + urgency_modifier + segment_value, 2)

            assert abs(priority - expected) < 0.01, \
                f"Customer {row[0]}: expected priority={expected}, got {priority}"

    def test_ordered_by_priority_score_desc_then_customer_id(self, recommendation_rows):
        """Validate results are ordered by priority_score DESC, then customer_id ASC."""
        prev_score = float('inf')
        prev_id = None
        for row in recommendation_rows:
            score = float(row[10])
            cust_id = row[0]
            if score == prev_score:
                assert cust_id >= prev_id, \
                    f"Secondary sort by customer_id failed: {prev_id} should come before {cust_id}"
            else:
                assert score <= prev_score, \
                    f"Primary sort by priority_score failed: {prev_score} should come before {score}"
            prev_score = score
            prev_id = cust_id


# ============ PHASE 5: rfm_cohort_retention ============

class TestPhase5CohortRetention:
    """Phase 5: Validate rfm_cohort_retention model."""

    def test_model_file_exists(self, dbt_run):
        """Validate the model file exists at the expected location."""
        dbt_dir = get_dbt_project_dir()
        model_path = os.path.join(dbt_dir, "models/marts/rfm/rfm_cohort_retention.sql")
        assert os.path.exists(model_path), \
            f"Model file not found at {model_path}"

    def test_model_exists_in_schema(self, dbt_run):
        """Validate rfm_cohort_retention model was created."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rfm_cohort_retention'
            """)
            assert int(result) > 0, f"Model rfm_cohort_retention not found in schema {MODEL_SCHEMA}"
        finally:
            conn.close()

    def test_all_required_columns(self, dbt_run):
        """Validate all required columns exist in rfm_cohort_retention."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = lower('{MODEL_SCHEMA}') AND lower(table_name) = 'rfm_cohort_retention'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                'cohort_month', 'months_since_first', 'cohort_size',
                'retained_customers', 'retention_rate',
                'cohort_revenue', 'avg_order_value'
            }
            missing = required - col_names
            assert not missing, f"Missing columns in rfm_cohort_retention: {missing}"
        finally:
            conn.close()

    def test_has_data(self, cohort_rows):
        """Validate model has data."""
        assert len(cohort_rows) > 0, "rfm_cohort_retention has no rows"

    def test_cohort_months_are_2024(self, cohort_rows):
        """Validate all cohort_month values are from 2024."""
        for row in cohort_rows:
            cohort = str(row[0])
            assert cohort.startswith('2024-'), f"Cohort month {cohort} is not from 2024"

    def test_months_since_first_non_negative(self, cohort_rows):
        """Validate months_since_first is non-negative."""
        for row in cohort_rows:
            months = int(row[1])
            assert months >= 0, f"Negative months_since_first: {months}"

    def test_retention_rate_range(self, cohort_rows):
        """Validate retention_rate is between 0 and 100."""
        for row in cohort_rows:
            rate = float(row[4])
            assert 0 <= rate <= 100, f"Invalid retention_rate {rate} for cohort {row[0]}"

    def test_retention_rate_at_month_0_is_100(self, cohort_rows):
        """Validate retention_rate at months_since_first=0 is 100%."""
        for row in cohort_rows:
            months = int(row[1])
            rate = float(row[4])
            if months == 0:
                assert rate == 100.0, \
                    f"Cohort {row[0]} retention at month 0 should be 100%, got {rate}"

    def test_retention_rate_calculation(self, cohort_rows):
        """Validate retention_rate = retained_customers / cohort_size * 100."""
        for row in cohort_rows:
            cohort_size = int(row[2])
            retained = int(row[3])
            rate = float(row[4])
            expected = round(retained * 100.0 / cohort_size, 2)
            assert abs(rate - expected) < 0.01, \
                f"Cohort {row[0]}, month {row[1]}: expected rate {expected}, got {rate}"

    def test_cohort_revenue_non_negative(self, cohort_rows):
        """Validate cohort_revenue is non-negative."""
        for row in cohort_rows:
            revenue = float(row[5])
            assert revenue >= 0, f"Negative cohort_revenue {revenue} for cohort {row[0]}"

    def test_ordered_by_cohort_then_months(self, cohort_rows):
        """Validate results are ordered by cohort_month ASC, months_since_first ASC."""
        prev_cohort = ''
        prev_months = -1
        for row in cohort_rows:
            cohort = str(row[0])
            months = int(row[1])
            if cohort == prev_cohort:
                assert months >= prev_months, \
                    f"months_since_first not ascending within cohort {cohort}"
            else:
                assert cohort >= prev_cohort, \
                    f"cohort_month not ascending: {prev_cohort} -> {cohort}"
            prev_cohort = cohort
            prev_months = months


# ============ PHASE 6: Cross-Model Consistency ============

class TestPhase6CrossModelConsistency:
    """Phase 6: Cross-model consistency checks."""

    def test_rfm_segment_consistency(self, rfm_rows, recommendation_rows):
        """Validate rfm_segment is consistent between models."""
        rfm_by_id = {row[0]: row[22] for row in rfm_rows}
        for rec_row in recommendation_rows:
            cust_id = rec_row[0]
            rec_segment = rec_row[1]
            rfm_segment = rfm_by_id.get(cust_id)
            assert rec_segment == rfm_segment, \
                f"Segment mismatch for {cust_id}: rfm has '{rfm_segment}', recommendation has '{rec_segment}'"

    def test_rfm_score_consistency(self, rfm_rows, recommendation_rows):
        """Validate rfm_score is consistent between models."""
        rfm_by_id = {row[0]: int(row[21]) for row in rfm_rows}
        for rec_row in recommendation_rows:
            cust_id = rec_row[0]
            rec_score = int(rec_row[2])
            rfm_score = rfm_by_id.get(cust_id)
            assert rec_score == rfm_score, \
                f"rfm_score mismatch for {cust_id}: rfm has {rfm_score}, recommendation has {rec_score}"

    def test_quarterly_trend_consistency(self, rfm_rows, recommendation_rows):
        """Validate quarterly_trend is consistent between models."""
        rfm_by_id = {row[0]: row[19] for row in rfm_rows}
        for rec_row in recommendation_rows:
            cust_id = rec_row[0]
            rec_trend = rec_row[3]
            rfm_trend = rfm_by_id.get(cust_id)
            assert rec_trend == rfm_trend, \
                f"quarterly_trend mismatch for {cust_id}: rfm has '{rfm_trend}', recommendation has '{rec_trend}'"

    def test_churn_probability_consistency(self, rfm_rows, recommendation_rows):
        """Validate churn_probability is consistent between models."""
        rfm_by_id = {row[0]: int(row[23]) for row in rfm_rows}
        for rec_row in recommendation_rows:
            cust_id = rec_row[0]
            rec_churn = int(rec_row[4])
            rfm_churn = rfm_by_id.get(cust_id)
            assert rec_churn == rfm_churn, \
                f"churn_probability mismatch for {cust_id}: rfm has {rfm_churn}, recommendation has {rec_churn}"

    def test_lifetime_value_consistency(self, rfm_rows, recommendation_rows):
        """Validate lifetime_value_estimate (estimated_value) is consistent between models."""
        rfm_by_id = {row[0]: float(row[24]) for row in rfm_rows}
        for rec_row in recommendation_rows:
            cust_id = rec_row[0]
            rec_value = float(rec_row[8])
            rfm_value = rfm_by_id.get(cust_id)
            assert abs(rec_value - rfm_value) < 0.01, \
                f"estimated_value mismatch for {cust_id}: rfm has {rfm_value}, recommendation has {rec_value}"


# ============ PHASE 7: Idempotency ============

class TestPhase7Idempotency:
    """Phase 7: Test that re-running produces same results."""

    def test_idempotency(self, rfm_rows, summary_rows, recommendation_rows, cohort_rows):
        """Test that re-running dbt produces the same results."""
        # Store before state
        rfm_before = sorted(list(rfm_rows), key=lambda x: x[0])
        summary_before = sorted(list(summary_rows), key=lambda x: x[0])
        rec_before = sorted(list(recommendation_rows), key=lambda x: x[0])
        cohort_before = sorted(list(cohort_rows), key=lambda x: (str(x[0]), int(x[1])))

        # Re-run dbt
        run_dbt_pipeline()

        # Get new results
        rfm_after = sorted(query_rfm_segments(), key=lambda x: x[0])
        summary_after = sorted(query_segment_summary(), key=lambda x: x[0])
        rec_after = sorted(query_recommendations(), key=lambda x: x[0])
        cohort_after = sorted(query_cohort_retention(), key=lambda x: (str(x[0]), int(x[1])))

        # Compare rfm_segments
        assert len(rfm_before) == len(rfm_after), "rfm_segments row count changed"
        for before, after in zip(rfm_before, rfm_after):
            assert before == after, f"rfm_segments row changed: {before} -> {after}"

        # Compare summary
        assert len(summary_before) == len(summary_after), "rpt_segment_summary row count changed"
        for before, after in zip(summary_before, summary_after):
            assert before == after, f"rpt_segment_summary row changed: {before} -> {after}"

        # Compare recommendations
        assert len(rec_before) == len(rec_after), "rpt_customer_recommendations row count changed"
        for before, after in zip(rec_before, rec_after):
            assert before == after, f"rpt_customer_recommendations row changed: {before} -> {after}"

        # Compare cohort retention
        assert len(cohort_before) == len(cohort_after), "rfm_cohort_retention row count changed"
        for before, after in zip(cohort_before, cohort_after):
            assert before == after, f"rfm_cohort_retention row changed: {before} -> {after}"
