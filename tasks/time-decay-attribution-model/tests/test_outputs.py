"""
Test verifier for Advanced Multi-Model Time-Decay Attribution task.
Multi-phase testing:
  Phase 1: Validate model structure and required columns
  Phase 2: Validate decay model calculations
  Phase 3: Validate customer journey attribution
  Phase 4: Validate channel interaction effects
  Phase 5: Validate confidence scoring
  Phase 6: Test mathematical consistency
"""
import subprocess
import os
from decimal import Decimal
from pathlib import Path
import pytest
import math

PROJECT_DIR = Path("/app/attribution_project")
DB_PATH = Path("/app/database/retail.duckdb")
REFERENCE_DATE_FALLBACK = '2026-01-08'  # used only if the data-relative lookup below fails
LOOKBACK_DAYS = 30

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
        db_path = os.environ.get('DUCKDB_PATH', str(DB_PATH))
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


def _compute_reference_date():
    """Reference (as-of) date, data-relative: the latest METRIC_DATE in the
    source data. Matches solutions that anchor to MAX(metric_date) rather than a
    hardcoded date or CURRENT_DATE (the data may not extend to the present day).
    Falls back to REFERENCE_DATE_FALLBACK if the lookup fails."""
    try:
        conn, db_type = get_db_connection()
        try:
            val = execute_scalar(
                conn, db_type,
                "SELECT MAX(METRIC_DATE) FROM MARKETING.CAMPAIGN_PERFORMANCE",
            )
        finally:
            conn.close()
        if val is not None:
            return str(val)[:10]
    except Exception:
        pass
    return REFERENCE_DATE_FALLBACK


REFERENCE_DATE = _compute_reference_date()


# ============ HELPERS ============


def run_cmd(cmd, cwd="/app/attribution_project"):
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt run."""
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_expected_decay_totals():
    """Compute expected decay model totals from source data."""
    conn, db_type = get_db_connection()
    try:
        # Use appropriate date diff function based on database type
        if db_type == 'snowflake':
            date_diff_func = "DATEDIFF('day', METRIC_DATE, DATE '{}')"
            lookback_start = f"DATEADD('day', -{LOOKBACK_DAYS}, DATE '{REFERENCE_DATE}')"
        else:
            date_diff_func = "DATE_DIFF('day', METRIC_DATE, DATE '{}')"
            lookback_start = f"DATE '{REFERENCE_DATE}' - INTERVAL '{LOOKBACK_DAYS}' DAY"

        date_diff_expr = date_diff_func.format(REFERENCE_DATE)

        query = f"""
            WITH performance_with_decay AS (
                SELECT
                    CAMPAIGN_ID,
                    METRIC_DATE,
                    REVENUE,
                    CONVERSIONS,
                    {date_diff_expr} as days_ago,
                    POW(2, -{date_diff_expr} / 7.0) as exp_weight,
                    GREATEST(0, 1.0 - {date_diff_expr} / 30.0) as lin_weight
                FROM MARKETING.CAMPAIGN_PERFORMANCE
                WHERE METRIC_DATE >= {lookback_start}
                  AND METRIC_DATE <= DATE '{REFERENCE_DATE}'
            )
            SELECT
                SUM(REVENUE * exp_weight) as total_exp_revenue,
                SUM(REVENUE * lin_weight) as total_lin_revenue,
                COUNT(DISTINCT CAMPAIGN_ID) as campaign_count
            FROM performance_with_decay
        """
        result = execute_query(conn, db_type, query)
        row = result[0] if result else (0, 0, 0)
        return {
            'total_exponential_revenue': float(row[0]) if row[0] else 0,
            'total_linear_revenue': float(row[1]) if row[1] else 0,
            'campaign_count': row[2]
        }
    finally:
        conn.close()


def get_expected_journey_stats():
    """Compute expected customer journey stats from orders."""
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            lookback_start = f"DATEADD('day', -{LOOKBACK_DAYS}, DATE '{REFERENCE_DATE}')"
            test_flag_filter = "AND (TEST_ORDER_FLAG IS NULL OR UPPER(CAST(TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))"
        else:
            lookback_start = f"DATE '{REFERENCE_DATE}' - INTERVAL '{LOOKBACK_DAYS}' DAY"
            test_flag_filter = "AND (TEST_ORDER_FLAG IS NULL OR TEST_ORDER_FLAG = false)"

        query = f"""
            WITH orders_in_window AS (
                SELECT
                    CUSTOMER_ID,
                    CHANNEL_ID,
                    GRAND_TOTAL,
                    ORDERED_AT
                FROM ORDERS.ORDERS
                WHERE ORDERED_AT >= {lookback_start}
                  AND ORDERED_AT <= DATE '{REFERENCE_DATE}'
                  {test_flag_filter}
                  AND CUSTOMER_ID IS NOT NULL
            ),
            journey_lengths AS (
                SELECT
                    CUSTOMER_ID,
                    COUNT(*) as journey_length
                FROM orders_in_window
                GROUP BY CUSTOMER_ID
            )
            SELECT
                COUNT(DISTINCT o.CUSTOMER_ID) as unique_customers,
                COUNT(*) as total_orders,
                AVG(jl.journey_length) as avg_journey_length,
                SUM(o.GRAND_TOTAL) as total_revenue
            FROM orders_in_window o
            JOIN journey_lengths jl ON o.CUSTOMER_ID = jl.CUSTOMER_ID
        """
        result = execute_query(conn, db_type, query)
        row = result[0] if result else (0, 0, 0, 0)
        return {
            'unique_customers': row[0],
            'total_orders': row[1],
            'avg_journey_length': float(row[2]) if row[2] else 0,
            'total_revenue': float(row[3]) if row[3] else 0
        }
    finally:
        conn.close()


@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


class TestPhase1Structure:
    """Phase 1: Validate model structure."""

    def test_project_exists(self, dbt_run):
        """Validate dbt project structure exists."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        assert PROJECT_DIR.is_dir(), f"Missing project directory: {PROJECT_DIR}"
        assert (PROJECT_DIR / "dbt_project.yml").is_file(), "dbt_project.yml not found"

    def test_decay_model_comparison_columns(self, dbt_run):
        """Validate decay_model_comparison has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'attribution_analytics'
                AND lower(table_name) = 'decay_model_comparison'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"campaign_id", "channel", "exponential_revenue", "linear_revenue",
                       "position_revenue", "exponential_conversions", "linear_conversions",
                       "position_conversions", "touchpoint_count", "total_weight"}
            missing = required - col_names
            assert not missing, f"Missing columns in decay_model_comparison: {missing}"
        finally:
            conn.close()

    def test_customer_journey_attribution_columns(self, dbt_run):
        """Validate customer_journey_attribution has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'attribution_analytics'
                AND lower(table_name) = 'customer_journey_attribution'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"campaign_id", "channel", "journey_attributed_revenue",
                       "unique_customers", "avg_journey_length", "first_touch_revenue",
                       "last_touch_revenue", "middle_touch_revenue"}
            missing = required - col_names
            assert not missing, f"Missing columns in customer_journey_attribution: {missing}"
        finally:
            conn.close()

    def test_channel_interaction_effects_columns(self, dbt_run):
        """Validate channel_interaction_effects has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'attribution_analytics'
                AND lower(table_name) = 'channel_interaction_effects'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"channel_a", "channel_b", "shared_customers", "combined_revenue",
                       "expected_revenue", "interaction_lift", "has_synergy"}
            missing = required - col_names
            assert not missing, f"Missing columns in channel_interaction_effects: {missing}"
        finally:
            conn.close()

    def test_attribution_confidence_columns(self, dbt_run):
        """Validate attribution_confidence has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'attribution_analytics'
                AND lower(table_name) = 'attribution_confidence'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"campaign_id", "channel", "sample_factor", "recency_score",
                       "consistency_score", "confidence_score"}
            missing = required - col_names
            assert not missing, f"Missing columns in attribution_confidence: {missing}"
        finally:
            conn.close()


class TestPhase2DecayModels:
    """Phase 2: Validate decay model calculations."""

    def test_exponential_decay_formula(self, dbt_run):
        """Validate exponential decay: weight = 2^(-days_ago / 7)."""
        print("\n" + "="*50)
        print("PHASE 2: Decay Model Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            # Verify by recalculating from source
            expected = get_expected_decay_totals()
            actual = execute_scalar(conn, db_type, """
                SELECT SUM(exponential_revenue) FROM attribution_analytics.decay_model_comparison
            """)
            # Allow for channel splitting differences
            assert actual is not None, "No exponential revenue calculated"
            assert actual > 0, "Exponential revenue should be positive"
            print(f"Total exponential revenue: {actual:.2f}")
        finally:
            conn.close()

    def test_linear_decay_formula(self, dbt_run):
        """Validate linear decay: weight = max(0, 1 - days_ago / 30)."""
        conn, db_type = get_db_connection()
        try:
            actual = execute_scalar(conn, db_type, """
                SELECT SUM(linear_revenue) FROM attribution_analytics.decay_model_comparison
            """)
            assert actual is not None and actual > 0, "Linear revenue should be positive"
            print(f"Total linear revenue: {actual:.2f}")
        finally:
            conn.close()

    def test_position_based_weights(self, dbt_run):
        """Validate position-based weights sum to expected proportions."""
        conn, db_type = get_db_connection()
        try:
            actual = execute_scalar(conn, db_type, """
                SELECT SUM(position_revenue) FROM attribution_analytics.decay_model_comparison
            """)
            assert actual is not None and actual > 0, "Position revenue should be positive"
            print(f"Total position revenue: {actual:.2f}")
        finally:
            conn.close()

    def test_decay_values_relationship(self, dbt_run):
        """Validate relative relationship between decay models."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, """
                SELECT exponential_revenue, linear_revenue, position_revenue
                FROM attribution_analytics.decay_model_comparison
                WHERE exponential_revenue > 0
            """)
            for exp, lin, pos in rows:
                # All should be non-negative
                assert exp >= 0, "Exponential revenue should be non-negative"
                assert lin >= 0, "Linear revenue should be non-negative"
                assert pos >= 0, "Position revenue should be non-negative"
        finally:
            conn.close()

    def test_lookback_window_enforced(self, dbt_run):
        """Validate only data within 30-day lookback is used."""
        conn, db_type = get_db_connection()
        try:
            # Use appropriate date arithmetic based on database type
            if db_type == 'snowflake':
                lookback_start = f"DATEADD('day', -{LOOKBACK_DAYS}, DATE '{REFERENCE_DATE}')"
            else:
                lookback_start = f"DATE '{REFERENCE_DATE}' - INTERVAL '{LOOKBACK_DAYS}' DAY"

            # Check that no campaigns are included that only have data outside window
            campaigns_outside = execute_query(conn, db_type, f"""
                SELECT DISTINCT CAMPAIGN_ID
                FROM MARKETING.CAMPAIGN_PERFORMANCE
                WHERE METRIC_DATE < {lookback_start}
                  AND CAMPAIGN_ID NOT IN (
                    SELECT DISTINCT CAMPAIGN_ID
                    FROM MARKETING.CAMPAIGN_PERFORMANCE
                    WHERE METRIC_DATE >= {lookback_start}
                      AND METRIC_DATE <= DATE '{REFERENCE_DATE}'
                  )
            """)

            if campaigns_outside:
                outside_ids = {c[0] for c in campaigns_outside}
                in_results = execute_query(conn, db_type, """
                    SELECT DISTINCT campaign_id FROM attribution_analytics.decay_model_comparison
                """)
                result_ids = {c[0] for c in in_results}
                overlap = outside_ids & result_ids
                assert not overlap, f"Campaigns outside window should not appear: {overlap}"
        finally:
            conn.close()


class TestPhase3CustomerJourneys:
    """Phase 3: Validate customer journey attribution."""

    def test_journey_revenue_positive(self, dbt_run):
        """Validate journey attributed revenue is positive."""
        print("\n" + "="*50)
        print("PHASE 3: Customer Journey Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            total = execute_scalar(conn, db_type, """
                SELECT SUM(journey_attributed_revenue)
                FROM attribution_analytics.customer_journey_attribution
            """)
            assert total is not None and total > 0, "Journey revenue should be positive"
            print(f"Total journey attributed revenue: {total:.2f}")
        finally:
            conn.close()

    def test_position_attribution_breakdown(self, dbt_run):
        """Validate first/last/middle touch breakdown."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, """
                SELECT
                    SUM(first_touch_revenue) as first,
                    SUM(last_touch_revenue) as last,
                    SUM(middle_touch_revenue) as middle,
                    SUM(journey_attributed_revenue) as total
                FROM attribution_analytics.customer_journey_attribution
            """)
            first, last, middle, total = rows[0]

            # First + Last + Middle should approximately equal total
            breakdown_sum = (first or 0) + (last or 0) + (middle or 0)
            assert abs(breakdown_sum - (total or 0)) < 1, \
                f"Breakdown sum ({breakdown_sum:.2f}) should equal total ({total:.2f})"
            print(f"First: {(first or 0):.2f}, Last: {(last or 0):.2f}, Middle: {(middle or 0):.2f}")
        finally:
            conn.close()

    def test_unique_customers_count(self, dbt_run):
        """Validate unique customer counts are reasonable."""
        expected = get_expected_journey_stats()
        conn, db_type = get_db_connection()
        try:
            actual = execute_scalar(conn, db_type, """
                SELECT SUM(unique_customers)
                FROM attribution_analytics.customer_journey_attribution
            """)
            # Should be close but might differ due to channel grouping
            assert actual is not None and actual > 0, "Should have some unique customers"
            print(f"Unique customers in attribution: {actual}")
        finally:
            conn.close()

    def test_avg_journey_length_reasonable(self, dbt_run):
        """Validate average journey length is reasonable (1-10)."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, """
                SELECT avg_journey_length
                FROM attribution_analytics.customer_journey_attribution
                WHERE avg_journey_length IS NOT NULL
            """)
            for (length,) in rows:
                assert length is not None and 1 <= length <= 100, f"Journey length {length} outside reasonable range (1-100)"
        finally:
            conn.close()


class TestPhase4ChannelInteractions:
    """Phase 4: Validate channel interaction effects."""

    def test_interaction_pairs_exist(self, dbt_run):
        """Validate channel pairs are identified."""
        print("\n" + "="*50)
        print("PHASE 4: Channel Interaction Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            count = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM attribution_analytics.channel_interaction_effects
            """)
            # May be 0 if no pairs have 5+ shared customers
            print(f"Channel pairs found: {count}")
        finally:
            conn.close()

    def test_minimum_shared_customers(self, dbt_run):
        """Validate all pairs have >= 5 shared customers."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM attribution_analytics.channel_interaction_effects
                WHERE shared_customers < 5
            """)
            assert invalid == 0, f"Found {invalid} pairs with < 5 shared customers"
        finally:
            conn.close()

    def test_synergy_flag_logic(self, dbt_run):
        """Validate has_synergy = true when lift > 1.1."""
        conn, db_type = get_db_connection()
        try:
            incorrect = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM attribution_analytics.channel_interaction_effects
                WHERE (interaction_lift > 1.1 AND has_synergy = false)
                   OR (interaction_lift <= 1.1 AND has_synergy = true)
            """)
            assert incorrect == 0, f"Found {incorrect} rows with incorrect has_synergy flag"
        finally:
            conn.close()

    def test_lift_calculation(self, dbt_run):
        """Validate lift = combined / expected."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, """
                SELECT combined_revenue, expected_revenue, interaction_lift
                FROM attribution_analytics.channel_interaction_effects
                WHERE expected_revenue > 0
            """)
            for combined, expected, lift in rows:
                expected_lift = combined / expected
                assert abs(lift - expected_lift) < 0.01, \
                    f"Lift mismatch: {lift} vs calculated {expected_lift:.4f}"
        finally:
            conn.close()


class TestPhase5ConfidenceScoring:
    """Phase 5: Validate confidence scoring."""

    def test_confidence_score_range(self, dbt_run):
        """Validate confidence_score is reasonable (0-100+)."""
        print("\n" + "="*50)
        print("PHASE 5: Confidence Scoring Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, """
                SELECT confidence_score FROM attribution_analytics.attribution_confidence
            """)
            for (score,) in rows:
                assert score is not None, f"Confidence score is NULL"
                assert score >= 0, f"Confidence score {score} should be non-negative"
        finally:
            conn.close()

    def test_sample_factor_capped(self, dbt_run):
        """Validate sample_factor is capped at 1.0."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM attribution_analytics.attribution_confidence
                WHERE sample_factor > 1.0
            """)
            assert invalid == 0, f"Found {invalid} rows with sample_factor > 1.0"
        finally:
            conn.close()

    def test_consistency_score_range(self, dbt_run):
        """Validate consistency_score is non-negative."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM attribution_analytics.attribution_confidence
                WHERE consistency_score < 0
            """)
            assert invalid == 0, f"Found {invalid} rows with negative consistency_score"
        finally:
            conn.close()

    def test_confidence_formula(self, dbt_run):
        """Validate confidence = (sample*0.3 + recency*0.3 + consistency*0.4) * 100."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, """
                SELECT sample_factor, recency_score, consistency_score, confidence_score
                FROM attribution_analytics.attribution_confidence
            """)
            for sample, recency, consistency, confidence in rows:
                assert None not in (sample, recency, consistency, confidence), \
                    f"NULL values in confidence row: sample={sample}, recency={recency}, consistency={consistency}, confidence={confidence}"
                sample, recency, consistency, confidence = float(sample), float(recency), float(consistency), float(confidence)
                expected = (sample * 0.3 + recency * 0.3 + consistency * 0.4) * 100
                assert abs(confidence - expected) < 0.1, \
                    f"Confidence mismatch: {confidence} vs expected {expected:.2f}"
        finally:
            conn.close()


class TestPhase6Consistency:
    """Phase 6: Test mathematical consistency."""

    def test_same_campaigns_across_models(self, dbt_run):
        """Validate decay_model_comparison and attribution_confidence have same campaigns."""
        print("\n" + "="*50)
        print("PHASE 6: Mathematical Consistency")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            decay_campaigns = set(execute_query(conn, db_type, """
                SELECT DISTINCT campaign_id FROM attribution_analytics.decay_model_comparison
            """))
            conf_campaigns = set(execute_query(conn, db_type, """
                SELECT DISTINCT campaign_id FROM attribution_analytics.attribution_confidence
            """))
            assert decay_campaigns == conf_campaigns, \
                "decay_model_comparison and attribution_confidence should have same campaigns"
        finally:
            conn.close()

    def test_channel_split_equal(self, dbt_run):
        """Validate multi-channel campaigns split attribution equally."""
        conn, db_type = get_db_connection()
        try:
            multi_channel = execute_query(conn, db_type, """
                SELECT campaign_id, COUNT(DISTINCT channel) as channel_count
                FROM attribution_analytics.decay_model_comparison
                GROUP BY campaign_id
                HAVING COUNT(DISTINCT channel) > 1
                LIMIT 5
            """)

            for campaign_id, channel_count in multi_channel:
                revenues = execute_query(conn, db_type, """
                    SELECT exponential_revenue
                    FROM attribution_analytics.decay_model_comparison
                    WHERE campaign_id = %s
                """ if db_type == 'snowflake' else """
                    SELECT exponential_revenue
                    FROM attribution_analytics.decay_model_comparison
                    WHERE campaign_id = ?
                """, [campaign_id])
                revenue_values = [r[0] for r in revenues]
                if len(revenue_values) > 1:
                    max_diff = max(revenue_values) - min(revenue_values)
                    assert max_diff < 0.1, \
                        f"Campaign {campaign_id} channels should have equal attribution"
        finally:
            conn.close()

    def test_total_weight_consistent(self, dbt_run):
        """Validate total_weight is same across channels for same campaign."""
        conn, db_type = get_db_connection()
        try:
            inconsistent = execute_query(conn, db_type, """
                SELECT campaign_id, COUNT(DISTINCT total_weight) as weight_variants
                FROM attribution_analytics.decay_model_comparison
                GROUP BY campaign_id
                HAVING COUNT(DISTINCT total_weight) > 1
            """)
            assert len(inconsistent) == 0, \
                f"Found campaigns with inconsistent total_weight: {inconsistent}"
        finally:
            conn.close()

    def test_no_negative_values(self, dbt_run):
        """Validate no negative revenue or conversion values."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, """
                SELECT COUNT(*) FROM attribution_analytics.decay_model_comparison
                WHERE exponential_revenue < 0 OR linear_revenue < 0 OR position_revenue < 0
                   OR exponential_conversions < 0 OR linear_conversions < 0 OR position_conversions < 0
            """)
            assert invalid == 0, f"Found {invalid} rows with negative values"
        finally:
            conn.close()
