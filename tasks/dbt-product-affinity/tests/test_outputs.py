"""
Test verifier for Product Affinity Analysis task.
Comprehensive multi-phase testing with validation for association rules,
temporal trends, customer segmentation, and sequential purchase analysis.
"""
import subprocess
import os
import pytest
import math

# ============ CONSTANTS ============

VALID_AFFINITY_CLASSES = ['Strong Positive', 'Moderate Positive', 'Weak Positive', 'Independent', 'Negative']
VALID_DIRECTIONS = ['A_to_B', 'B_to_A', 'Equal']
VALID_TRENDS = ['Strengthening', 'Weakening', 'Stable', 'New', 'Discontinued']
VALID_CUSTOMER_SEGMENTS = ['First-Time Favorite', 'Repeat Favorite', 'Universal']
VALID_LEAD_PRODUCTS = ['Product A Leads', 'Product B Leads', 'No Clear Leader', 'Insufficient Data']

MIN_CO_PURCHASE_COUNT = 3
MIN_SUPPORT = 0.0001
MIN_PRODUCT_ORDERS_FOR_SUMMARY = 10

AFFINITY_COLUMNS = [
    "product_a_id", "product_a_name", "product_b_id", "product_b_name",
    "co_purchase_count", "product_a_orders", "product_b_orders", "total_orders",
    "support", "confidence_a_to_b", "confidence_b_to_a", "lift",
    "conviction_a_to_b", "conviction_b_to_a", "kulczynski", "imbalance_ratio", "jaccard",
    "affinity_class", "stronger_direction", "confidence_ratio",
    "pair_revenue", "avg_pair_basket_value", "pair_revenue_contribution_pct", "pair_rank",
    "early_co_purchase_count", "recent_co_purchase_count", "trend_classification",
    "first_time_co_purchases", "repeat_co_purchases", "first_time_pct", "customer_affinity_segment",
    "sequential_customers", "a_first_count", "b_first_count", "a_first_pct",
    "avg_days_a_to_b", "avg_days_b_to_a", "lead_product"
]

SUMMARY_COLUMNS = [
    "product_id", "product_name", "product_total_orders", "product_total_revenue",
    "rank", "associated_product_id", "associated_product_name",
    "co_purchase_count", "confidence", "lift", "trend_classification", "customer_affinity_segment"
]

CATEGORY_COLUMNS = [
    "category_a_id", "category_b_id", "co_purchase_count",
    "category_a_orders", "category_b_orders", "support",
    "confidence_a_to_b", "confidence_b_to_a", "lift", "kulczynski", "jaccard",
    "affinity_class", "avg_products_per_pair_order", "pair_revenue", "unique_product_pairs"
]

TRENDS_COLUMNS = [
    "product_a_id", "product_b_id", "order_month", "monthly_co_purchases",
    "monthly_pair_revenue", "cumulative_co_purchases", "cumulative_pair_revenue",
    "month_rank", "pct_of_total_co_purchases", "monthly_first_time_pct"
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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')



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
    """Run the dbt pipeline for all affinity models."""
    result = run_cmd("dbt run --select int_affinity_order_products int_affinity_product_stats int_affinity_product_pairs product_affinity product_affinity_summary category_affinity affinity_trends")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_product_affinity():
    """Query the product_affinity table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT product_a_id, product_a_name, product_b_id, product_b_name,
                           co_purchase_count, product_a_orders, product_b_orders, total_orders,
                           support, confidence_a_to_b, confidence_b_to_a, lift,
                           conviction_a_to_b, conviction_b_to_a, kulczynski, imbalance_ratio, jaccard,
                           affinity_class, stronger_direction, confidence_ratio,
                           pair_revenue, avg_pair_basket_value, pair_revenue_contribution_pct, pair_rank,
                           early_co_purchase_count, recent_co_purchase_count, trend_classification,
                           first_time_co_purchases, repeat_co_purchases, first_time_pct, customer_affinity_segment,
                           sequential_customers, a_first_count, b_first_count, a_first_pct,
                           avg_days_a_to_b, avg_days_b_to_a, lead_product
                    FROM {schema}.product_affinity
                    ORDER BY co_purchase_count DESC, product_a_id, product_b_id
                """)
            except:
                continue
        raise Exception("product_affinity not found")
    finally:
        conn.close()


def query_affinity_summary():
    """Query the product_affinity_summary table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT product_id, product_name, product_total_orders, product_total_revenue,
                           rank, associated_product_id, associated_product_name,
                           co_purchase_count, confidence, lift, trend_classification, customer_affinity_segment
                    FROM {schema}.product_affinity_summary
                    ORDER BY product_id, rank
                """)
            except:
                continue
        raise Exception("product_affinity_summary not found")
    finally:
        conn.close()


def query_category_affinity():
    """Query the category_affinity table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT category_a_id, category_b_id, co_purchase_count,
                           category_a_orders, category_b_orders, support,
                           confidence_a_to_b, confidence_b_to_a, lift, kulczynski, jaccard,
                           affinity_class, avg_products_per_pair_order, pair_revenue, unique_product_pairs
                    FROM {schema}.category_affinity
                    ORDER BY co_purchase_count DESC
                """)
            except:
                continue
        raise Exception("category_affinity not found")
    finally:
        conn.close()


def query_affinity_trends():
    """Query the affinity_trends table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT product_a_id, product_b_id, order_month, monthly_co_purchases,
                           monthly_pair_revenue, cumulative_co_purchases, cumulative_pair_revenue,
                           month_rank, pct_of_total_co_purchases, monthly_first_time_pct
                    FROM {schema}.affinity_trends
                    ORDER BY product_a_id, product_b_id, order_month
                """)
            except:
                continue
        raise Exception("affinity_trends not found")
    finally:
        conn.close()


def query_order_products():
    """Query the intermediate order products table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['intermediate', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT order_id, customer_id, product_id, product_name, product_order_revenue, ordered_at, is_first_order
                    FROM {schema}.int_affinity_order_products
                    ORDER BY order_id, product_id
                """)
            except:
                continue
        return execute_query(conn, db_type, """
            SELECT order_id, customer_id, product_id, product_name, product_order_revenue, ordered_at, is_first_order
            FROM int_affinity_order_products
            ORDER BY order_id, product_id
        """)
    finally:
        conn.close()


# ============ FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Run dbt pipeline once before all tests."""
    run_dbt_pipeline()


@pytest.fixture(scope="module")
def affinity_rows(dbt_run):
    """Get product affinity rows."""
    return query_product_affinity()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    """Get affinity summary rows."""
    return query_affinity_summary()


@pytest.fixture(scope="module")
def category_rows(dbt_run):
    """Get category affinity rows."""
    return query_category_affinity()


@pytest.fixture(scope="module")
def trends_rows(dbt_run):
    """Get affinity trends rows."""
    return query_affinity_trends()


@pytest.fixture(scope="module")
def order_products(dbt_run):
    """Get intermediate order products."""
    return query_order_products()


# ============ PHASE 1: STRUCTURE TESTS ============

class TestPhase1Structure:
    """Verify basic model structure and existence."""

    def test_model_exists(self, affinity_rows):
        """Product affinity model exists and has data."""
        assert len(affinity_rows) > 0, "product_affinity has no rows"

    def test_columns_count(self, affinity_rows):
        """All 38 columns present."""
        assert len(affinity_rows[0]) == 38, f"Expected 38 columns, got {len(affinity_rows[0])}"

    def test_summary_exists(self, summary_rows):
        """Summary table exists and has data."""
        assert len(summary_rows) > 0, "product_affinity_summary has no rows"

    def test_category_exists(self, category_rows):
        """Category affinity table exists and has data."""
        assert len(category_rows) > 0, "category_affinity has no rows"

    def test_trends_exists(self, trends_rows):
        """Affinity trends table exists and has data."""
        assert len(trends_rows) > 0, "affinity_trends has no rows"


# ============ PHASE 2: PAIR ORDERING TESTS ============

class TestPhase2PairOrdering:
    """Verify product pair ordering constraint (A < B)."""

    def test_product_a_less_than_b(self, affinity_rows):
        """Product A ID is always lexicographically less than Product B ID."""
        for r in affinity_rows:
            assert r[0] < r[2], f"Ordering violation: {r[0]} >= {r[2]}"

    def test_no_duplicate_pairs(self, affinity_rows):
        """No duplicate product pairs."""
        pairs = set()
        for r in affinity_rows:
            pair = (r[0], r[2])
            assert pair not in pairs, f"Duplicate pair: {pair}"
            pairs.add(pair)

    def test_category_a_less_than_b(self, category_rows):
        """Category A ID is always less than Category B ID."""
        for r in category_rows:
            assert r[0] < r[1], f"Category ordering violation: {r[0]} >= {r[1]}"


# ============ PHASE 3: THRESHOLD TESTS ============

class TestPhase3Thresholds:
    """Verify minimum thresholds are applied."""

    def test_min_co_purchase_count(self, affinity_rows):
        """All pairs have co_purchase_count >= 3."""
        for r in affinity_rows:
            assert r[4] >= MIN_CO_PURCHASE_COUNT, f"co_purchase_count {r[4]} < {MIN_CO_PURCHASE_COUNT}"

    def test_min_support(self, affinity_rows):
        """All pairs have support >= 0.0001."""
        for r in affinity_rows:
            support = float(r[8])
            assert support >= MIN_SUPPORT, f"support {support} < {MIN_SUPPORT}"

    def test_summary_min_orders(self, summary_rows):
        """Summary only includes products with 10+ orders."""
        for r in summary_rows:
            assert r[2] >= MIN_PRODUCT_ORDERS_FOR_SUMMARY, f"product_total_orders {r[2]} < {MIN_PRODUCT_ORDERS_FOR_SUMMARY}"


# ============ PHASE 4: CORE ASSOCIATION RULES ============

class TestPhase4CoreMetrics:
    """Verify core association rule calculations."""

    def test_support_calculation(self, affinity_rows):
        """Support = co_purchase_count / total_orders."""
        for r in affinity_rows[:50]:
            co_purchase = r[4]
            total_orders = r[7]
            support = float(r[8])
            expected = co_purchase / total_orders
            assert abs(support - expected) < 0.000001, f"Support mismatch: {support} != {expected}"

    def test_confidence_a_to_b(self, affinity_rows):
        """Confidence A->B = co_purchase_count / product_a_orders."""
        for r in affinity_rows[:50]:
            co_purchase = r[4]
            product_a_orders = r[5]
            confidence = float(r[9])
            expected = co_purchase / product_a_orders
            assert abs(confidence - expected) < 0.0001, f"Confidence A->B mismatch"

    def test_confidence_b_to_a(self, affinity_rows):
        """Confidence B->A = co_purchase_count / product_b_orders."""
        for r in affinity_rows[:50]:
            co_purchase = r[4]
            product_b_orders = r[6]
            confidence = float(r[10])
            expected = co_purchase / product_b_orders
            assert abs(confidence - expected) < 0.0001, f"Confidence B->A mismatch"

    def test_lift_calculation(self, affinity_rows):
        """Lift = (co_purchase * total) / (a_orders * b_orders)."""
        for r in affinity_rows[:50]:
            co_purchase = r[4]
            product_a_orders = r[5]
            product_b_orders = r[6]
            total_orders = r[7]
            lift = float(r[11])
            expected = (co_purchase * total_orders) / (product_a_orders * product_b_orders)
            assert abs(lift - expected) < 0.001, f"Lift mismatch: {lift} != {expected}"

    def test_confidence_range(self, affinity_rows):
        """Confidence values are between 0 and 1."""
        for r in affinity_rows:
            conf_a = float(r[9])
            conf_b = float(r[10])
            assert 0 <= conf_a <= 1, f"Invalid confidence A->B: {conf_a}"
            assert 0 <= conf_b <= 1, f"Invalid confidence B->A: {conf_b}"


# ============ PHASE 5: ADVANCED METRICS ============

class TestPhase5AdvancedMetrics:
    """Verify advanced association metrics."""

    def test_kulczynski_calculation(self, affinity_rows):
        """Kulczynski = (conf_a_to_b + conf_b_to_a) / 2."""
        for r in affinity_rows[:50]:
            conf_a = float(r[9])
            conf_b = float(r[10])
            kulc = float(r[14])
            expected = (conf_a + conf_b) / 2
            assert abs(kulc - expected) < 0.0001, f"Kulczynski mismatch: {kulc} != {expected}"

    def test_imbalance_ratio_range(self, affinity_rows):
        """Imbalance ratio is between 0 and 1."""
        for r in affinity_rows:
            imb = float(r[15])
            assert 0 <= imb <= 1, f"Invalid imbalance ratio: {imb}"

    def test_imbalance_ratio_calculation(self, affinity_rows):
        """Imbalance ratio = |conf_a - conf_b| / (conf_a + conf_b)."""
        for r in affinity_rows[:50]:
            conf_a = float(r[9])
            conf_b = float(r[10])
            imb = float(r[15])
            if conf_a + conf_b > 0:
                expected = abs(conf_a - conf_b) / (conf_a + conf_b)
                assert abs(imb - expected) < 0.001, f"Imbalance mismatch"

    def test_jaccard_calculation(self, affinity_rows):
        """Jaccard = co_purchase / (a_orders + b_orders - co_purchase)."""
        for r in affinity_rows[:50]:
            co_purchase = r[4]
            a_orders = r[5]
            b_orders = r[6]
            jaccard = float(r[16])
            expected = co_purchase / (a_orders + b_orders - co_purchase)
            assert abs(jaccard - expected) < 0.0001, f"Jaccard mismatch"

    def test_jaccard_range(self, affinity_rows):
        """Jaccard is between 0 and 1."""
        for r in affinity_rows:
            jacc = float(r[16])
            assert 0 <= jacc <= 1, f"Invalid Jaccard: {jacc}"


# ============ PHASE 6: CONVICTION ============

class TestPhase6Conviction:
    """Verify conviction calculations."""

    def test_conviction_positive(self, affinity_rows):
        """Conviction values are positive."""
        for r in affinity_rows:
            conv_a = float(r[12])
            conv_b = float(r[13])
            assert conv_a > 0, f"Negative conviction A: {conv_a}"
            assert conv_b > 0, f"Negative conviction B: {conv_b}"

    def test_conviction_edge_case(self, affinity_rows):
        """Perfect confidence -> conviction = 999.99."""
        for r in affinity_rows:
            conf_a = float(r[9])
            conv_a = float(r[12])
            if conf_a >= 1.0:
                assert conv_a == 999.99, f"Expected 999.99 for perfect confidence"


# ============ PHASE 7: CLASSIFICATION ============

class TestPhase7Classification:
    """Verify affinity classification."""

    def test_valid_affinity_classes(self, affinity_rows):
        """All affinity classes are valid."""
        for r in affinity_rows:
            assert r[17] in VALID_AFFINITY_CLASSES, f"Invalid class: {r[17]}"

    def test_strong_positive(self, affinity_rows):
        """Strong Positive requires lift >= 3.0."""
        for r in affinity_rows:
            lift = float(r[11])
            if r[17] == 'Strong Positive':
                assert lift >= 3.0, f"Strong Positive with lift {lift}"

    def test_negative(self, affinity_rows):
        """Negative requires lift < 1.0."""
        for r in affinity_rows:
            lift = float(r[11])
            if r[17] == 'Negative':
                assert lift < 1.0, f"Negative with lift {lift}"


# ============ PHASE 8: DIRECTIONALITY ============

class TestPhase8Directionality:
    """Verify directionality analysis."""

    def test_valid_directions(self, affinity_rows):
        """All directions are valid."""
        for r in affinity_rows:
            assert r[18] in VALID_DIRECTIONS, f"Invalid direction: {r[18]}"

    def test_direction_logic(self, affinity_rows):
        """Direction matches confidence comparison."""
        for r in affinity_rows[:50]:
            conf_a = float(r[9])
            conf_b = float(r[10])
            direction = r[18]
            if conf_a > conf_b:
                assert direction == 'A_to_B'
            elif conf_b > conf_a:
                assert direction == 'B_to_A'
            else:
                assert direction == 'Equal'


# ============ PHASE 9: TEMPORAL TRENDS ============

class TestPhase9TemporalTrends:
    """Verify temporal trend analysis."""

    def test_valid_trends(self, affinity_rows):
        """All trend classifications are valid."""
        for r in affinity_rows:
            assert r[26] in VALID_TRENDS, f"Invalid trend: {r[26]}"

    def test_early_recent_sum(self, affinity_rows):
        """early + recent <= total co_purchase_count."""
        for r in affinity_rows:
            total = r[4]
            early = r[24]
            recent = r[25]
            assert early + recent == total, f"early({early}) + recent({recent}) != total({total})"

    def test_new_classification(self, affinity_rows):
        """New means early_co_purchase_count = 0."""
        for r in affinity_rows:
            if r[26] == 'New':
                assert r[24] == 0, f"New but early_count = {r[24]}"

    def test_discontinued_classification(self, affinity_rows):
        """Discontinued means recent_co_purchase_count = 0."""
        for r in affinity_rows:
            if r[26] == 'Discontinued':
                assert r[25] == 0, f"Discontinued but recent_count = {r[25]}"


# ============ PHASE 10: CUSTOMER SEGMENTATION ============

class TestPhase10CustomerSegmentation:
    """Verify customer segmentation analysis."""

    def test_valid_customer_segments(self, affinity_rows):
        """All customer segments are valid."""
        for r in affinity_rows:
            assert r[30] in VALID_CUSTOMER_SEGMENTS, f"Invalid segment: {r[30]}"

    def test_first_time_repeat_sum(self, affinity_rows):
        """first_time + repeat = total co_purchase_count."""
        for r in affinity_rows:
            total = r[4]
            first_time = r[27]
            repeat = r[28]
            assert first_time + repeat == total, f"first_time({first_time}) + repeat({repeat}) != total({total})"

    def test_first_time_pct_range(self, affinity_rows):
        """first_time_pct is between 0 and 100."""
        for r in affinity_rows:
            pct = float(r[29])
            assert 0 <= pct <= 100, f"Invalid first_time_pct: {pct}"

    def test_segment_logic(self, affinity_rows):
        """Segment classification matches percentage."""
        for r in affinity_rows[:50]:
            pct = float(r[29])
            segment = r[30]
            if pct >= 60:
                assert segment == 'First-Time Favorite', f"pct={pct} but segment={segment}"
            elif pct <= 40:
                assert segment == 'Repeat Favorite', f"pct={pct} but segment={segment}"
            else:
                assert segment == 'Universal', f"pct={pct} but segment={segment}"


# ============ PHASE 11: SEQUENTIAL ANALYSIS ============

class TestPhase11Sequential:
    """Verify sequential purchase analysis."""

    def test_valid_lead_products(self, affinity_rows):
        """All lead product values are valid."""
        for r in affinity_rows:
            assert r[37] in VALID_LEAD_PRODUCTS, f"Invalid lead_product: {r[37]}"

    def test_insufficient_data_threshold(self, affinity_rows):
        """Insufficient Data when sequential_customers < 3."""
        for r in affinity_rows:
            seq_customers = r[31]
            lead = r[37]
            if seq_customers < 3:
                assert lead == 'Insufficient Data', f"seq={seq_customers} but lead={lead}"

    def test_a_b_first_sum(self, affinity_rows):
        """a_first + b_first + same_day = sequential_customers."""
        # Note: same_day_count not exposed, but a_first + b_first <= sequential
        for r in affinity_rows:
            seq = r[31]
            a_first = r[32]
            b_first = r[33]
            assert a_first + b_first <= seq, f"a_first + b_first > sequential"

    def test_avg_days_null_when_insufficient(self, affinity_rows):
        """avg_days fields are NULL when sequential_customers < 3."""
        for r in affinity_rows:
            seq = r[31]
            avg_a_to_b = r[35]
            avg_b_to_a = r[36]
            if seq < 3:
                assert avg_a_to_b is None, f"avg_days_a_to_b not null when seq < 3"
                assert avg_b_to_a is None, f"avg_days_b_to_a not null when seq < 3"


# ============ PHASE 12: REVENUE METRICS ============

class TestPhase12Revenue:
    """Verify revenue-related metrics."""

    def test_pair_revenue_positive(self, affinity_rows):
        """Pair revenue is positive."""
        for r in affinity_rows:
            revenue = float(r[20])
            assert revenue > 0, f"Non-positive pair revenue: {revenue}"

    def test_basket_value_positive(self, affinity_rows):
        """Average basket value is positive."""
        for r in affinity_rows:
            basket = float(r[21])
            assert basket > 0, f"Non-positive basket value: {basket}"

    def test_revenue_contribution_range(self, affinity_rows):
        """Revenue contribution is between 0 and 100."""
        for r in affinity_rows:
            contrib = float(r[22])
            assert 0 <= contrib <= 100, f"Invalid contribution: {contrib}"


# ============ PHASE 13: RANKING ============

class TestPhase13Ranking:
    """Verify pair ranking."""

    def test_rank_starts_at_1(self, affinity_rows):
        """Pair ranks start at 1."""
        ranks = [r[23] for r in affinity_rows]
        assert min(ranks) == 1, f"Min rank is {min(ranks)}"

    def test_rank_order(self, affinity_rows):
        """Ranks follow co_purchase_count order."""
        prev_count = float('inf')
        prev_rank = 0
        for r in affinity_rows:
            count = r[4]
            rank = r[23]
            if count < prev_count:
                assert rank >= prev_rank
            prev_count = count
            prev_rank = rank


# ============ PHASE 14: SUMMARY TABLE ============

class TestPhase14Summary:
    """Verify product affinity summary table."""

    def test_rank_range(self, summary_rows):
        """Summary ranks are 1-5."""
        for r in summary_rows:
            rank = r[4]
            assert 1 <= rank <= 5, f"Invalid rank: {rank}"

    def test_max_5_per_product(self, summary_rows):
        """Each product has at most 5 associations."""
        from collections import Counter
        counts = Counter(r[0] for r in summary_rows)
        for prod, count in counts.items():
            assert count <= 5, f"Product {prod} has {count} associations"

    def test_summary_has_trends(self, summary_rows):
        """Summary includes trend_classification."""
        for r in summary_rows:
            assert r[10] in VALID_TRENDS, f"Invalid trend in summary: {r[10]}"

    def test_summary_has_segments(self, summary_rows):
        """Summary includes customer_affinity_segment."""
        for r in summary_rows:
            assert r[11] in VALID_CUSTOMER_SEGMENTS, f"Invalid segment in summary: {r[11]}"


# ============ PHASE 15: CATEGORY AFFINITY ============

class TestPhase15Category:
    """Verify category affinity table."""

    def test_no_self_pairs(self, category_rows):
        """No category self-pairs."""
        for r in category_rows:
            assert r[0] != r[1], f"Self-pair: {r[0]}"

    def test_category_has_kulczynski(self, category_rows):
        """Category has kulczynski metric."""
        for r in category_rows[:20]:
            kulc = float(r[9])
            assert 0 <= kulc <= 1, f"Invalid kulczynski: {kulc}"

    def test_category_has_jaccard(self, category_rows):
        """Category has jaccard metric."""
        for r in category_rows[:20]:
            jacc = float(r[10])
            assert 0 <= jacc <= 1, f"Invalid jaccard: {jacc}"

    def test_unique_product_pairs(self, category_rows):
        """unique_product_pairs is non-negative."""
        for r in category_rows:
            assert r[14] >= 0, f"Negative unique_product_pairs: {r[14]}"


# ============ PHASE 16: AFFINITY TRENDS ============

class TestPhase16Trends:
    """Verify affinity trends table."""

    def test_month_format(self, trends_rows):
        """Month format is YYYY-MM."""
        import re
        for r in trends_rows[:100]:
            assert re.match(r'^\d{4}-\d{2}$', r[2]), f"Invalid month: {r[2]}"

    def test_cumulative_increases(self, trends_rows):
        """Cumulative values increase or stay same."""
        prev = {}
        for r in trends_rows:
            key = (r[0], r[1])
            cum = r[5]
            if key in prev:
                assert cum >= prev[key], f"Cumulative decreased for {key}"
            prev[key] = cum

    def test_month_rank_sequence(self, trends_rows):
        """month_rank starts at 1 for each pair."""
        from collections import defaultdict
        pair_ranks = defaultdict(list)
        for r in trends_rows:
            key = (r[0], r[1])
            pair_ranks[key].append(r[7])
        for key, ranks in pair_ranks.items():
            assert min(ranks) == 1, f"Pair {key} min rank is {min(ranks)}"

    def test_pct_of_total_range(self, trends_rows):
        """pct_of_total_co_purchases is between 0 and 100."""
        for r in trends_rows:
            pct = float(r[8])
            assert 0 <= pct <= 100, f"Invalid pct: {pct}"


# ============ PHASE 17: DATA FILTERING ============

class TestPhase17Filtering:
    """Verify data filtering rules."""

    def test_multi_product_orders_only(self, order_products):
        """Only orders with 2+ products are included."""
        from collections import Counter
        order_counts = Counter(r[0] for r in order_products)
        for order_id, count in order_counts.items():
            assert count >= 2, f"Order {order_id} has only {count} product(s)"


# ============ PHASE 18: CONSISTENCY ============

class TestPhase18Consistency:
    """Cross-table consistency checks."""

    def test_total_orders_consistent(self, affinity_rows):
        """Total orders is consistent across all pairs."""
        totals = set(r[7] for r in affinity_rows)
        assert len(totals) == 1, f"Inconsistent total_orders: {totals}"

    def test_co_purchase_reasonable(self, affinity_rows):
        """Co-purchase count <= min(a_orders, b_orders)."""
        for r in affinity_rows:
            co = r[4]
            a = r[5]
            b = r[6]
            assert co <= min(a, b), f"co_purchase {co} > min({a}, {b})"


# ============ PHASE 19: MATERIALIZATION ============

class TestPhase19Materialization:
    """Verify materialization types."""

    def test_affinity_is_table(self, dbt_run):
        """product_affinity is a table."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'product_affinity'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()

    def test_trends_is_table(self, dbt_run):
        """affinity_trends is a table."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'affinity_trends'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()


# ============ PHASE 20: IDEMPOTENCY ============

class TestPhase20Idempotency:
    """Verify idempotency."""

    def test_idempotency(self, affinity_rows):
        """Re-running dbt produces identical results."""
        original_count = len(affinity_rows)
        original_first = affinity_rows[0] if affinity_rows else None

        run_dbt_pipeline()

        new_rows = query_product_affinity()
        assert len(new_rows) == original_count, f"Row count changed"
        if original_first:
            assert new_rows[0] == original_first, "First row changed"
