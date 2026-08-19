"""
Test verifier for Coupon Effectiveness Analysis task.
Multi-phase testing with comprehensive validation for promotion metrics,
redemption calculations, and customer acquisition analysis.
"""
import subprocess
import os
import pytest
import re

# ============ CONSTANTS ============

VALID_PERFORMANCE_TIERS = ['High Performer', 'Medium Performer', 'Low Performer']
VALID_EFFICIENCY_RATINGS = ['Excellent', 'Good', 'Average', 'Poor']
VALID_CUSTOMER_FOCUS = ['Acquisition', 'Retention', 'Balanced']
VALID_ACTIVITY_STATUS = ['Active', 'Dormant', 'Inactive']

EFFECTIVENESS_COLUMNS = [
    "promotion_id", "promotion_name", "promotion_type", "discount_type",
    "discount_value", "total_coupons", "total_redemptions", "unique_customers",
    "unique_orders", "repeat_redeemer_count", "repeat_redeemer_pct",
    "total_discount_given", "total_order_value", "total_order_value_before_discount",
    "avg_discount_per_redemption", "avg_order_value", "avg_order_value_before_discount",
    "discount_to_revenue_ratio", "revenue_per_discount_dollar", "total_usage_limit",
    "redemption_rate", "avg_redemptions_per_coupon", "avg_redemptions_per_customer",
    "first_time_redemptions", "repeat_redemptions", "first_time_pct",
    "new_customer_acquisition_cost", "first_redemption_date", "last_redemption_date",
    "days_active", "avg_daily_redemptions", "activity_status",
    "performance_tier", "efficiency_rating", "customer_focus", "revenue_rank",
    "top_customer_redemptions", "top_customer_pct", "single_use_customer_count",
    "single_use_customer_pct", "concentration_risk",
    "early_redemption_count", "late_redemption_count",
    "early_avg_order_value", "late_avg_order_value",
    "early_avg_discount", "late_avg_discount",
    "order_value_decay_pct", "decay_classification"
]

VALID_CONCENTRATION_RISK = ['High', 'Medium', 'Low']
VALID_DECAY_CLASSIFICATION = ['Improving', 'Stable', 'Declining', 'Collapsing']

SUMMARY_COLUMNS = [
    "promotion_type", "discount_type", "promotion_count", "total_redemptions",
    "unique_customers", "total_discount_given", "total_order_value",
    "avg_discount_per_redemption", "avg_order_value", "revenue_per_discount_dollar",
    "first_time_pct", "pct_of_total_redemptions", "pct_of_total_revenue",
    "high_performer_count", "excellent_efficiency_count"
]

TRENDS_COLUMNS = [
    "promotion_id", "promotion_name", "redemption_month", "monthly_redemptions",
    "monthly_discount", "monthly_order_value", "monthly_unique_customers",
    "monthly_first_time_count", "cumulative_redemptions", "cumulative_discount",
    "cumulative_order_value", "month_rank", "pct_of_total_redemptions",
    "monthly_revenue_per_discount",
    "weekday_redemptions", "weekend_redemptions",
    "weekday_order_value", "weekend_order_value",
    "weekday_avg_order_value", "weekend_avg_order_value", "weekend_lift_pct"
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


# ============ HELPERS ============
def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')



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
    """Run the dbt pipeline for all coupon models."""
    result = run_cmd("dbt run --select int_coupon_redemptions coupon_effectiveness coupon_summary coupon_trends")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_coupon_effectiveness():
    """Query the coupon_effectiveness table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT promotion_id, promotion_name, promotion_type, discount_type,
                           discount_value, total_coupons, total_redemptions, unique_customers,
                           unique_orders, repeat_redeemer_count, repeat_redeemer_pct,
                           total_discount_given, total_order_value, total_order_value_before_discount,
                           avg_discount_per_redemption, avg_order_value, avg_order_value_before_discount,
                           discount_to_revenue_ratio, revenue_per_discount_dollar, total_usage_limit,
                           redemption_rate, avg_redemptions_per_coupon, avg_redemptions_per_customer,
                           first_time_redemptions, repeat_redemptions, first_time_pct,
                           new_customer_acquisition_cost, first_redemption_date, last_redemption_date,
                           days_active, avg_daily_redemptions, activity_status,
                           performance_tier, efficiency_rating, customer_focus, revenue_rank,
                           top_customer_redemptions, top_customer_pct, single_use_customer_count,
                           single_use_customer_pct, concentration_risk,
                           early_redemption_count, late_redemption_count,
                           early_avg_order_value, late_avg_order_value,
                           early_avg_discount, late_avg_discount,
                           order_value_decay_pct, decay_classification
                    FROM {schema}.coupon_effectiveness
                    ORDER BY revenue_rank ASC
                """)
            except:
                continue
        raise Exception("coupon_effectiveness not found")
    finally:
        conn.close()


def query_coupon_summary():
    """Query the coupon_summary table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT promotion_type, discount_type, promotion_count, total_redemptions,
                           unique_customers, total_discount_given, total_order_value,
                           avg_discount_per_redemption, avg_order_value, revenue_per_discount_dollar,
                           first_time_pct, pct_of_total_redemptions, pct_of_total_revenue,
                           high_performer_count, excellent_efficiency_count
                    FROM {schema}.coupon_summary
                    ORDER BY total_order_value DESC
                """)
            except:
                continue
        raise Exception("coupon_summary not found")
    finally:
        conn.close()


def query_coupon_trends():
    """Query the coupon_trends table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT promotion_id, promotion_name, redemption_month, monthly_redemptions,
                           monthly_discount, monthly_order_value, monthly_unique_customers,
                           monthly_first_time_count, cumulative_redemptions, cumulative_discount,
                           cumulative_order_value, month_rank, pct_of_total_redemptions,
                           monthly_revenue_per_discount,
                           weekday_redemptions, weekend_redemptions,
                           weekday_order_value, weekend_order_value,
                           weekday_avg_order_value, weekend_avg_order_value, weekend_lift_pct
                    FROM {schema}.coupon_trends
                    ORDER BY promotion_id, redemption_month
                """)
            except:
                continue
        raise Exception("coupon_trends not found")
    finally:
        conn.close()


# ============ FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Run dbt pipeline once before all tests."""
    run_dbt_pipeline()


@pytest.fixture(scope="module")
def effectiveness_rows(dbt_run):
    """Get coupon effectiveness rows."""
    return query_coupon_effectiveness()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    """Get coupon summary rows."""
    return query_coupon_summary()


@pytest.fixture(scope="module")
def trends_rows(dbt_run):
    """Get coupon trends rows."""
    return query_coupon_trends()


# ============ PHASE 1: STRUCTURE TESTS ============

class TestPhase1Structure:
    """Verify basic model structure and existence."""

    def test_effectiveness_exists(self, effectiveness_rows):
        """Coupon effectiveness model exists and has data."""
        print("\n" + "="*50 + "\nPHASE 1: Structure\n" + "="*50)
        assert len(effectiveness_rows) > 0, "coupon_effectiveness has no rows"

    def test_effectiveness_columns(self, effectiveness_rows):
        """All 49 columns present in effectiveness."""
        assert len(effectiveness_rows[0]) == 49, f"Expected 49 columns, got {len(effectiveness_rows[0])}"

    def test_summary_exists(self, summary_rows):
        """Summary table exists and has data."""
        assert len(summary_rows) > 0, "coupon_summary has no rows"

    def test_trends_exists(self, trends_rows):
        """Trends table exists and has data."""
        assert len(trends_rows) > 0, "coupon_trends has no rows"


# ============ PHASE 2: VALID VALUES ============

class TestPhase2ValidValues:
    """Verify all classification values are valid."""

    def test_valid_performance_tiers(self, effectiveness_rows):
        """All performance tiers are valid."""
        print("\n" + "="*50 + "\nPHASE 2: Valid Values\n" + "="*50)
        for r in effectiveness_rows:
            assert r[32] in VALID_PERFORMANCE_TIERS, f"Invalid tier: {r[32]}"

    def test_valid_efficiency_ratings(self, effectiveness_rows):
        """All efficiency ratings are valid."""
        for r in effectiveness_rows:
            assert r[33] in VALID_EFFICIENCY_RATINGS, f"Invalid rating: {r[33]}"

    def test_valid_customer_focus(self, effectiveness_rows):
        """All customer focus values are valid."""
        for r in effectiveness_rows:
            assert r[34] in VALID_CUSTOMER_FOCUS, f"Invalid focus: {r[34]}"

    def test_valid_activity_status(self, effectiveness_rows):
        """All activity status values are valid."""
        for r in effectiveness_rows:
            assert r[31] in VALID_ACTIVITY_STATUS, f"Invalid status: {r[31]}"


# ============ PHASE 3: POSITIVE VALUES ============

class TestPhase3PositiveValues:
    """Verify required fields have positive values."""

    def test_positive_redemptions(self, effectiveness_rows):
        """Total redemptions are positive."""
        print("\n" + "="*50 + "\nPHASE 3: Positive Values\n" + "="*50)
        for r in effectiveness_rows:
            assert r[6] > 0, f"Non-positive redemptions: {r[6]}"

    def test_positive_customers(self, effectiveness_rows):
        """Unique customers are positive."""
        for r in effectiveness_rows:
            assert r[7] > 0, f"Non-positive customers: {r[7]}"

    def test_positive_discount(self, effectiveness_rows):
        """Total discount is positive."""
        for r in effectiveness_rows:
            assert float(r[11]) > 0, f"Non-positive discount: {r[11]}"

    def test_positive_order_value(self, effectiveness_rows):
        """Total order value is positive."""
        for r in effectiveness_rows:
            assert float(r[12]) > 0, f"Non-positive order value: {r[12]}"


# ============ PHASE 4: CALCULATION TESTS ============

class TestPhase4Calculations:
    """Verify key calculations are correct."""

    def test_order_value_before_discount(self, effectiveness_rows):
        """Order value before discount = order value + discount."""
        print("\n" + "="*50 + "\nPHASE 4: Calculations\n" + "="*50)
        for r in effectiveness_rows[:20]:
            order_val = float(r[12])
            discount = float(r[11])
            before = float(r[13])
            expected = round(order_val + discount, 2)
            assert abs(before - expected) < 0.1, f"Before discount mismatch: {before} != {expected}"

    def test_avg_discount_calculation(self, effectiveness_rows):
        """Avg discount = total discount / total redemptions."""
        for r in effectiveness_rows[:20]:
            total_discount = float(r[11])
            total_redemptions = r[6]
            avg_discount = float(r[14])
            expected = round(total_discount / total_redemptions, 2)
            assert abs(avg_discount - expected) < 0.1, f"Avg discount mismatch"

    def test_avg_order_value_calculation(self, effectiveness_rows):
        """Avg order value = total order value / unique orders."""
        for r in effectiveness_rows[:20]:
            if r[12] is None or r[8] is None or r[15] is None:
                continue
            total_order = float(r[12])
            unique_orders = r[8]
            avg_order = float(r[15])
            expected = round(total_order / unique_orders, 2)
            assert abs(avg_order - expected) < 0.1, f"Avg order mismatch"

    def test_revenue_per_discount(self, effectiveness_rows):
        """Revenue per discount = order value / discount."""
        for r in effectiveness_rows[:20]:
            order_val = float(r[12])
            discount = float(r[11])
            rpd = float(r[18])
            expected = round(order_val / discount, 2)
            assert abs(rpd - expected) < 0.1, f"Revenue per discount mismatch"

    def test_first_time_plus_repeat_equals_total(self, effectiveness_rows):
        """First-time + repeat redemptions = total redemptions."""
        for r in effectiveness_rows:
            total = r[6]
            first_time = r[23]
            repeat = r[24]
            assert first_time + repeat == total, f"Redemptions don't sum: {first_time} + {repeat} != {total}"


# ============ PHASE 5: PERCENTAGE RANGES ============

class TestPhase5PercentageRanges:
    """Verify percentages are within valid ranges."""

    def test_repeat_redeemer_pct_range(self, effectiveness_rows):
        """Repeat redeemer percentage is 0-100."""
        print("\n" + "="*50 + "\nPHASE 5: Percentage Ranges\n" + "="*50)
        for r in effectiveness_rows:
            pct = float(r[10]) if r[10] is not None else 0
            assert 0 <= pct <= 100, f"Invalid repeat pct: {pct}"

    def test_first_time_pct_range(self, effectiveness_rows):
        """First-time percentage is 0-100."""
        for r in effectiveness_rows:
            pct = float(r[25]) if r[25] is not None else 0
            assert 0 <= pct <= 100, f"Invalid first-time pct: {pct}"

    def test_redemption_rate_range(self, effectiveness_rows):
        """Redemption rate is 0-100+ (can exceed if over limit)."""
        for r in effectiveness_rows:
            if r[20] is not None:  # redemption_rate can be NULL for unlimited
                rate = float(r[20])
                assert rate >= 0, f"Negative redemption rate: {rate}"


# ============ PHASE 6: CLASSIFICATION LOGIC ============

class TestPhase6ClassificationLogic:
    """Verify classification logic is correct."""

    def test_efficiency_excellent(self, effectiveness_rows):
        """Excellent efficiency requires revenue_per_discount >= 10."""
        print("\n" + "="*50 + "\nPHASE 6: Classification Logic\n" + "="*50)
        for r in effectiveness_rows:
            rpd = float(r[18])
            rating = r[33]
            if rating == 'Excellent':
                assert rpd >= 10, f"Excellent with rpd={rpd}"

    def test_efficiency_poor(self, effectiveness_rows):
        """Poor efficiency requires revenue_per_discount < 2."""
        for r in effectiveness_rows:
            rpd = float(r[18])
            rating = r[33]
            if rating == 'Poor':
                assert rpd < 2, f"Poor with rpd={rpd}"

    def test_customer_focus_acquisition(self, effectiveness_rows):
        """Acquisition focus requires first_time_pct >= 50."""
        for r in effectiveness_rows:
            pct = float(r[25]) if r[25] is not None else 0
            focus = r[34]
            if focus == 'Acquisition':
                assert pct >= 50, f"Acquisition with first_time_pct={pct}"

    def test_customer_focus_retention(self, effectiveness_rows):
        """Retention focus requires first_time_pct < 30."""
        for r in effectiveness_rows:
            pct = float(r[25]) if r[25] is not None else 0
            focus = r[34]
            if focus == 'Retention':
                assert pct < 30, f"Retention with first_time_pct={pct}"


# ============ PHASE 7: RANKING ============

class TestPhase7Ranking:
    """Verify ranking is correct."""

    def test_rank_starts_at_1(self, effectiveness_rows):
        """Revenue rank starts at 1."""
        print("\n" + "="*50 + "\nPHASE 7: Ranking\n" + "="*50)
        assert effectiveness_rows[0][35] == 1, f"First rank is {effectiveness_rows[0][35]}"

    def test_revenue_descending_by_rank(self, effectiveness_rows):
        """Higher rank = higher revenue."""
        prev_revenue = float('inf')
        prev_rank = 0
        for r in effectiveness_rows:
            revenue = float(r[12])
            rank = r[35]
            if rank > prev_rank:
                assert revenue <= prev_revenue, "Revenue not descending with rank"
            prev_revenue = revenue
            prev_rank = rank


# ============ PHASE 8: TEMPORAL METRICS ============

class TestPhase8TemporalMetrics:
    """Verify temporal metrics."""

    def test_days_active_positive(self, effectiveness_rows):
        """Days active is positive."""
        print("\n" + "="*50 + "\nPHASE 8: Temporal Metrics\n" + "="*50)
        for r in effectiveness_rows:
            assert r[29] >= 1, f"Days active < 1: {r[29]}"

    def test_first_before_last(self, effectiveness_rows):
        """First redemption date <= last redemption date."""
        for r in effectiveness_rows:
            first = r[27]
            last = r[28]
            assert first <= last, f"First {first} > Last {last}"


# ============ PHASE 9: SUMMARY CONSISTENCY ============

class TestPhase9SummaryConsistency:
    """Verify summary table consistency."""

    def test_summary_totals_match(self, summary_rows, effectiveness_rows):
        """Summary total redemptions match effectiveness."""
        print("\n" + "="*50 + "\nPHASE 9: Summary Consistency\n" + "="*50)
        summary_total = sum(r[3] for r in summary_rows)
        effectiveness_total = sum(r[6] for r in effectiveness_rows)
        assert summary_total == effectiveness_total, f"Redemption totals don't match"

    def test_pct_sums_to_100(self, summary_rows):
        """Percentage of total redemptions sums to ~100."""
        total = sum(float(r[11]) for r in summary_rows)
        assert abs(total - 100) < 1.0, f"Redemption pct sum is {total}"

    def test_revenue_pct_sums_to_100(self, summary_rows):
        """Percentage of total revenue sums to ~100."""
        total = sum(float(r[12]) for r in summary_rows)
        assert abs(total - 100) < 1.0, f"Revenue pct sum is {total}"


# ============ PHASE 10: TRENDS CONSISTENCY ============

class TestPhase10TrendsConsistency:
    """Verify trends table consistency."""

    def test_month_format(self, trends_rows):
        """Month format is YYYY-MM."""
        print("\n" + "="*50 + "\nPHASE 10: Trends Consistency\n" + "="*50)
        for r in trends_rows[:50]:
            assert re.match(r'^\d{4}-\d{2}$', r[2]), f"Invalid month: {r[2]}"

    def test_cumulative_increases(self, trends_rows):
        """Cumulative values increase monotonically."""
        prev = {}
        for r in trends_rows:
            key = r[0]  # promotion_id
            cum = r[8]  # cumulative_redemptions
            if key in prev:
                assert cum >= prev[key], f"Cumulative decreased for {key}"
            prev[key] = cum

    def test_month_rank_sequence(self, trends_rows):
        """Month rank starts at 1 for each promotion."""
        from collections import defaultdict
        promo_ranks = defaultdict(list)
        for r in trends_rows:
            promo_ranks[r[0]].append(r[11])
        for promo, ranks in promo_ranks.items():
            assert min(ranks) == 1, f"Promotion {promo} min rank is {min(ranks)}"


# ============ PHASE 11: UNIQUE PROMOTIONS ============

class TestPhase11UniquePromotions:
    """Verify promotion uniqueness."""

    def test_unique_promotion_ids(self, effectiveness_rows):
        """No duplicate promotion IDs."""
        print("\n" + "="*50 + "\nPHASE 11: Unique Promotions\n" + "="*50)
        promo_ids = [r[0] for r in effectiveness_rows]
        assert len(promo_ids) == len(set(promo_ids)), "Duplicate promotion IDs"


# ============ PHASE 12: MATERIALIZATION ============

class TestPhase12Materialization:
    """Verify materialization types."""

    def test_effectiveness_is_table(self, dbt_run):
        """coupon_effectiveness is a table."""
        print("\n" + "="*50 + "\nPHASE 12: Materialization\n" + "="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'coupon_effectiveness'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()

    def test_summary_is_table(self, dbt_run):
        """coupon_summary is a table."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'coupon_summary'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()

    def test_trends_is_table(self, dbt_run):
        """coupon_trends is a table."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'coupon_trends'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()


# ============ PHASE 13: IDEMPOTENCY ============

class TestPhase13Idempotency:
    """Verify idempotency."""

    def test_idempotency(self, effectiveness_rows):
        """Re-running dbt produces identical results."""
        print("\n" + "="*50 + "\nPHASE 13: Idempotency\n" + "="*50)
        original_count = len(effectiveness_rows)
        original_first = effectiveness_rows[0] if effectiveness_rows else None

        run_dbt_pipeline()

        new_rows = query_coupon_effectiveness()
        assert len(new_rows) == original_count, f"Row count changed"
        if original_first:
            assert new_rows[0] == original_first, "First row changed"


# ============ PHASE 14: ACQUISITION COST FORMULA ============

class TestPhase14AcquisitionCostFormula:
    """Verify new_customer_acquisition_cost formula correctness."""

    def test_acquisition_cost_null_when_no_first_timers(self, effectiveness_rows):
        """Acquisition cost is NULL when first_time_redemptions = 0."""
        print("\n" + "="*50 + "\nPHASE 14: Acquisition Cost Formula\n" + "="*50)
        for r in effectiveness_rows:
            first_time = r[23]  # first_time_redemptions
            acq_cost = r[26]    # new_customer_acquisition_cost
            if first_time == 0:
                assert acq_cost is None, f"Acquisition cost should be NULL when 0 first-timers, got {acq_cost}"

    def test_acquisition_cost_positive_when_first_timers(self, effectiveness_rows):
        """Acquisition cost is positive when there are first-time redemptions."""
        for r in effectiveness_rows:
            first_time = r[23]  # first_time_redemptions
            acq_cost = r[26]    # new_customer_acquisition_cost
            if first_time > 0:
                assert acq_cost is not None, "Acquisition cost should not be NULL when first-timers exist"
                assert float(acq_cost) > 0, f"Acquisition cost should be positive, got {acq_cost}"

    def test_acquisition_cost_formula_verification(self, dbt_run):
        """Verify acquisition cost = first_time_discount / first_time_redemptions."""
        conn, db_type = get_db_connection()
        try:
            # Query intermediate model for first-time discount totals per promotion
            for schema in ['intermediate', 'main']:
                try:
                    first_time_data = execute_query(conn, db_type, f"""
                        SELECT
                            promotion_id,
                            SUM(discount_amount) as first_time_discount,
                            COUNT(*) as first_time_count
                        FROM {schema}.int_coupon_redemptions
                        WHERE is_first_order = 1 OR is_first_order = true
                        GROUP BY promotion_id
                    """)
                    break
                except:
                    continue
            else:
                # If int_coupon_redemptions not accessible, skip this test
                return

            # Build lookup dict
            ft_lookup = {r[0]: (float(r[1]), r[2]) for r in first_time_data}

            # Query effectiveness and verify
            effectiveness = query_coupon_effectiveness()
            for r in effectiveness[:20]:  # Check first 20 promotions
                promo_id = r[0]
                acq_cost = r[26]
                first_time_count = r[23]

                if promo_id in ft_lookup and first_time_count > 0:
                    expected_discount, expected_count = ft_lookup[promo_id]
                    if expected_count > 0:
                        expected_cost = round(expected_discount / expected_count, 2)
                        actual_cost = float(acq_cost) if acq_cost else 0
                        assert abs(actual_cost - expected_cost) < 0.1, \
                            f"Acquisition cost mismatch for {promo_id}: {actual_cost} != {expected_cost}"
        finally:
            conn.close()


# ============ PHASE 15: ANALYSIS PERIOD BOUNDARIES ============

class TestPhase15AnalysisPeriodBoundaries:
    """Verify data respects analysis period boundaries."""

    def test_redemption_dates_within_period(self, effectiveness_rows):
        """All redemption dates are within the analysis period."""
        print("\n" + "="*50 + "\nPHASE 15: Analysis Period Boundaries\n" + "="*50)
        from datetime import date
        period_start = date(2023, 1, 1)
        period_end = date(2024, 12, 1)  # exclusive

        for r in effectiveness_rows:
            first_date = r[27]  # first_redemption_date
            last_date = r[28]   # last_redemption_date
            assert first_date >= period_start, f"First date {first_date} before period start"
            assert last_date < period_end, f"Last date {last_date} on or after period end"

    def test_trends_months_within_period(self, trends_rows):
        """All trend months are within the analysis period."""
        for r in trends_rows:
            month = r[2]  # redemption_month (YYYY-MM)
            assert month >= '2023-01', f"Month {month} before 2023-01"
            assert month <= '2024-11', f"Month {month} after 2024-11"


# ============ PHASE 16: CUSTOMER CONCENTRATION RISK ============

class TestPhase16CustomerConcentration:
    """Verify customer concentration risk metrics."""

    def test_valid_concentration_risk(self, effectiveness_rows):
        """All concentration risk values are valid."""
        print("\n" + "="*50 + "\nPHASE 16: Customer Concentration\n" + "="*50)
        for r in effectiveness_rows:
            assert r[40] in VALID_CONCENTRATION_RISK, f"Invalid concentration risk: {r[40]}"

    def test_top_customer_pct_range(self, effectiveness_rows):
        """Top customer percentage is 0-100."""
        for r in effectiveness_rows:
            pct = float(r[37]) if r[37] is not None else 0
            assert 0 <= pct <= 100, f"Invalid top customer pct: {pct}"

    def test_single_use_customer_pct_range(self, effectiveness_rows):
        """Single use customer percentage is 0-100."""
        for r in effectiveness_rows:
            pct = float(r[39]) if r[39] is not None else 0
            assert 0 <= pct <= 100, f"Invalid single use pct: {pct}"

    def test_top_customer_redemptions_lte_total(self, effectiveness_rows):
        """Top customer redemptions <= total redemptions."""
        for r in effectiveness_rows:
            top_redemptions = r[36]  # top_customer_redemptions
            total_redemptions = r[6]  # total_redemptions
            assert top_redemptions <= total_redemptions, \
                f"Top customer redemptions {top_redemptions} > total {total_redemptions}"

    def test_single_use_count_lte_unique_customers(self, effectiveness_rows):
        """Single use customer count <= unique customers."""
        for r in effectiveness_rows:
            single_use = r[38]  # single_use_customer_count
            unique = r[7]  # unique_customers
            assert single_use <= unique, f"Single use {single_use} > unique {unique}"

    def test_concentration_risk_classification(self, effectiveness_rows):
        """Concentration risk classification is correct."""
        for r in effectiveness_rows:
            pct = float(r[37]) if r[37] is not None else 0
            risk = r[40]
            if risk == 'High':
                assert pct >= 50, f"High risk with pct={pct}"
            elif risk == 'Low':
                assert pct < 30, f"Low risk with pct={pct}"


# ============ PHASE 17: PROMOTION EFFECTIVENESS DECAY ============

class TestPhase17EffectivenessDecay:
    """Verify promotion effectiveness decay metrics."""

    def test_valid_decay_classification(self, effectiveness_rows):
        """All decay classification values are valid."""
        print("\n" + "="*50 + "\nPHASE 17: Effectiveness Decay\n" + "="*50)
        for r in effectiveness_rows:
            assert r[48] in VALID_DECAY_CLASSIFICATION, f"Invalid decay classification: {r[48]}"

    def test_early_late_sum_equals_total(self, effectiveness_rows):
        """Early + late redemption count = total redemptions."""
        for r in effectiveness_rows:
            total = r[6]  # total_redemptions
            early = r[41]  # early_redemption_count
            late = r[42]  # late_redemption_count
            if early is not None and late is not None:
                assert early + late == total, f"Early {early} + Late {late} != Total {total}"

    def test_early_avg_positive(self, effectiveness_rows):
        """Early average order value is positive."""
        for r in effectiveness_rows:
            early_avg = r[43]  # early_avg_order_value
            if early_avg is not None:
                assert float(early_avg) > 0, f"Non-positive early avg: {early_avg}"

    def test_decay_classification_logic(self, effectiveness_rows):
        """Decay classification follows the rules."""
        for r in effectiveness_rows:
            decay_pct = r[47]  # order_value_decay_pct
            classification = r[48]  # decay_classification
            if decay_pct is None:
                assert classification == 'Stable', f"NULL decay should be Stable, got {classification}"
            else:
                decay = float(decay_pct)
                if classification == 'Improving':
                    assert decay < -10, f"Improving with decay={decay}"
                elif classification == 'Collapsing':
                    assert decay > 30, f"Collapsing with decay={decay}"


# ============ PHASE 18: WEEKDAY/WEEKEND ANALYSIS ============

class TestPhase18WeekdayWeekend:
    """Verify weekday/weekend analysis in trends."""

    def test_weekday_weekend_sum_equals_monthly(self, trends_rows):
        """Weekday + weekend redemptions = monthly redemptions."""
        print("\n" + "="*50 + "\nPHASE 18: Weekday/Weekend Analysis\n" + "="*50)
        for r in trends_rows:
            monthly = r[3]  # monthly_redemptions
            weekday = r[14]  # weekday_redemptions
            weekend = r[15]  # weekend_redemptions
            assert weekday + weekend == monthly, \
                f"Weekday {weekday} + Weekend {weekend} != Monthly {monthly}"

    def test_weekday_order_value_non_negative(self, trends_rows):
        """Weekday order value is non-negative."""
        for r in trends_rows:
            weekday_value = float(r[16]) if r[16] is not None else 0
            assert weekday_value >= 0, f"Negative weekday order value: {weekday_value}"

    def test_weekend_order_value_non_negative(self, trends_rows):
        """Weekend order value is non-negative."""
        for r in trends_rows:
            weekend_value = float(r[17]) if r[17] is not None else 0
            assert weekend_value >= 0, f"Negative weekend order value: {weekend_value}"

    def test_weekday_avg_null_when_zero_redemptions(self, trends_rows):
        """Weekday avg is NULL when weekday redemptions = 0."""
        for r in trends_rows:
            weekday_redemptions = r[14]
            weekday_avg = r[18]
            if weekday_redemptions == 0:
                assert weekday_avg is None, f"Weekday avg should be NULL when 0 redemptions"

    def test_weekend_avg_null_when_zero_redemptions(self, trends_rows):
        """Weekend avg is NULL when weekend redemptions = 0."""
        for r in trends_rows:
            weekend_redemptions = r[15]
            weekend_avg = r[19]
            if weekend_redemptions == 0:
                assert weekend_avg is None, f"Weekend avg should be NULL when 0 redemptions"

    def test_weekend_lift_null_conditions(self, trends_rows):
        """Weekend lift is NULL when weekday or weekend has 0 redemptions."""
        for r in trends_rows:
            weekday_redemptions = r[14]
            weekend_redemptions = r[15]
            weekend_lift = r[20]
            if weekday_redemptions == 0 or weekend_redemptions == 0:
                assert weekend_lift is None, \
                    f"Weekend lift should be NULL when weekday={weekday_redemptions}, weekend={weekend_redemptions}"
