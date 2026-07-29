"""
Test verifier for ABC Inventory Classification task.
Multi-phase testing with comprehensive validation for Pareto analysis,
cumulative calculations, and ABC classification logic.
"""
import subprocess
import os
import pytest
import re

# ============ CONSTANTS ============

VALID_ABC_CLASSES = ['A', 'B', 'C']
VALID_VELOCITY = ['High', 'Medium', 'Low']
VALID_CONCENTRATION = ['A-Heavy', 'Balanced', 'C-Heavy']

ABC_THRESHOLDS = {
    'A': 80.0,
    'B': 95.0,
    'C': 100.0
}

CLASSIFICATION_COLUMNS = [
    "product_id", "product_name", "category_id", "total_revenue",
    "total_quantity_sold", "order_count", "avg_unit_price", "avg_order_value",
    "revenue_pct", "cumulative_revenue", "cumulative_revenue_pct",
    "revenue_rank", "quantity_rank", "abc_class", "is_pareto_product",
    "avg_monthly_revenue", "first_sale_month", "last_sale_month",
    "months_active", "revenue_velocity"
]

SUMMARY_COLUMNS = [
    "abc_class", "product_count", "product_pct", "total_revenue", "revenue_pct",
    "total_quantity", "quantity_pct", "avg_revenue_per_product",
    "avg_orders_per_product", "min_revenue", "max_revenue", "median_revenue",
    "high_velocity_count", "medium_velocity_count", "low_velocity_count"
]

CATEGORY_COLUMNS = [
    "category_id", "total_products", "total_revenue",
    "a_class_count", "b_class_count", "c_class_count",
    "a_class_pct", "b_class_pct", "c_class_pct",
    "a_class_revenue", "b_class_revenue", "c_class_revenue",
    "a_revenue_pct", "b_revenue_pct", "c_revenue_pct",
    "category_concentration"
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
            schema='analytics',
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
    """Run the dbt pipeline for all ABC models."""
    result = run_cmd("dbt run --select int_abc_product_revenue abc_classification abc_summary abc_category_breakdown")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_abc_classification():
    """Query the abc_classification table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT product_id, product_name, category_id, total_revenue,
                           total_quantity_sold, order_count, avg_unit_price, avg_order_value,
                           revenue_pct, cumulative_revenue, cumulative_revenue_pct,
                           revenue_rank, quantity_rank, abc_class, is_pareto_product,
                           avg_monthly_revenue, first_sale_month, last_sale_month,
                           months_active, revenue_velocity
                    FROM {schema}.abc_classification
                    ORDER BY revenue_rank ASC
                """)
            except:
                continue
        raise Exception("abc_classification not found")
    finally:
        conn.close()


def query_abc_summary():
    """Query the abc_summary table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT abc_class, product_count, product_pct, total_revenue, revenue_pct,
                           total_quantity, quantity_pct, avg_revenue_per_product,
                           avg_orders_per_product, min_revenue, max_revenue, median_revenue,
                           high_velocity_count, medium_velocity_count, low_velocity_count
                    FROM {schema}.abc_summary
                    ORDER BY abc_class ASC
                """)
            except:
                continue
        raise Exception("abc_summary not found")
    finally:
        conn.close()


def query_category_breakdown():
    """Query the abc_category_breakdown table."""
    conn, db_type = get_db_connection()
    try:
        for schema in ['analytics', 'marts', 'main']:
            try:
                return execute_query(conn, db_type, f"""
                    SELECT category_id, total_products, total_revenue,
                           a_class_count, b_class_count, c_class_count,
                           a_class_pct, b_class_pct, c_class_pct,
                           a_class_revenue, b_class_revenue, c_class_revenue,
                           a_revenue_pct, b_revenue_pct, c_revenue_pct,
                           category_concentration
                    FROM {schema}.abc_category_breakdown
                    ORDER BY total_revenue DESC
                """)
            except:
                continue
        raise Exception("abc_category_breakdown not found")
    finally:
        conn.close()


def is_truthy(v):
    """Check if a value is truthy."""
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v == 1
    if isinstance(v, str):
        return v.lower() in ('1', 'true', 't')
    return bool(v)


# ============ FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Run dbt pipeline once before all tests."""
    run_dbt_pipeline()


@pytest.fixture(scope="module")
def classification_rows(dbt_run):
    """Get ABC classification rows."""
    return query_abc_classification()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    """Get ABC summary rows."""
    return query_abc_summary()


@pytest.fixture(scope="module")
def category_rows(dbt_run):
    """Get category breakdown rows."""
    return query_category_breakdown()


# ============ PHASE 1: STRUCTURE TESTS ============

class TestPhase1Structure:
    """Verify basic model structure and existence."""

    def test_classification_exists(self, classification_rows):
        """ABC classification model exists and has data."""
        print("\n" + "="*50 + "\nPHASE 1: Structure\n" + "="*50)
        assert len(classification_rows) > 0, "abc_classification has no rows"

    def test_classification_columns(self, classification_rows):
        """All 20 columns present in classification."""
        assert len(classification_rows[0]) == 20, f"Expected 20 columns, got {len(classification_rows[0])}"

    def test_summary_exists(self, summary_rows):
        """Summary table exists and has data."""
        assert len(summary_rows) > 0, "abc_summary has no rows"

    def test_summary_has_all_classes(self, summary_rows):
        """Summary has exactly 3 rows (A, B, C)."""
        classes = [r[0] for r in summary_rows]
        assert set(classes) == set(VALID_ABC_CLASSES), f"Expected A, B, C, got {classes}"

    def test_category_exists(self, category_rows):
        """Category breakdown table exists and has data."""
        assert len(category_rows) > 0, "abc_category_breakdown has no rows"


# ============ PHASE 2: NO NULLS ============

class TestPhase2NoNulls:
    """Verify no NULL values in required fields."""

    def test_no_nulls_classification(self, classification_rows):
        """No NULL values in classification table."""
        print("\n" + "="*50 + "\nPHASE 2: No NULLs\n" + "="*50)
        for row in classification_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL in column {CLASSIFICATION_COLUMNS[i]} for product {row[0]}"

    def test_no_nulls_summary(self, summary_rows):
        """No NULL values in summary table."""
        for row in summary_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL in column {SUMMARY_COLUMNS[i]} for class {row[0]}"


# ============ PHASE 3: VALID VALUES ============

class TestPhase3ValidValues:
    """Verify all values are within valid ranges."""

    def test_valid_abc_classes(self, classification_rows):
        """All ABC classes are valid (A, B, C)."""
        print("\n" + "="*50 + "\nPHASE 3: Valid Values\n" + "="*50)
        for r in classification_rows:
            assert r[13] in VALID_ABC_CLASSES, f"Invalid ABC class: {r[13]}"

    def test_valid_velocity(self, classification_rows):
        """All velocity values are valid."""
        for r in classification_rows:
            assert r[19] in VALID_VELOCITY, f"Invalid velocity: {r[19]}"

    def test_valid_concentration(self, category_rows):
        """All concentration values are valid."""
        for r in category_rows:
            assert r[15] in VALID_CONCENTRATION, f"Invalid concentration: {r[15]}"

    def test_positive_revenue(self, classification_rows):
        """All revenue values are positive."""
        for r in classification_rows:
            assert float(r[3]) > 0, f"Non-positive revenue: {r[3]}"

    def test_positive_quantities(self, classification_rows):
        """All quantity values are positive."""
        for r in classification_rows:
            assert r[4] > 0, f"Non-positive quantity: {r[4]}"
            assert r[5] > 0, f"Non-positive order count: {r[5]}"


# ============ PHASE 4: ORDERING ============

class TestPhase4Ordering:
    """Verify ordering is correct."""

    def test_revenue_rank_starts_at_1(self, classification_rows):
        """Revenue rank starts at 1."""
        print("\n" + "="*50 + "\nPHASE 4: Ordering\n" + "="*50)
        assert classification_rows[0][11] == 1, f"First rank is {classification_rows[0][11]}"

    def test_revenue_descending_order(self, classification_rows):
        """Products are ordered by revenue descending."""
        prev_revenue = float('inf')
        for r in classification_rows:
            revenue = float(r[3])
            assert revenue <= prev_revenue, f"Revenue not descending: {revenue} > {prev_revenue}"
            prev_revenue = revenue

    def test_summary_ordering(self, summary_rows):
        """Summary is ordered A, B, C."""
        classes = [r[0] for r in summary_rows]
        assert classes == ['A', 'B', 'C'], f"Summary order is {classes}"

    def test_category_revenue_descending(self, category_rows):
        """Categories ordered by revenue descending."""
        prev_revenue = float('inf')
        for r in category_rows:
            revenue = float(r[2])
            assert revenue <= prev_revenue, f"Category revenue not descending"
            prev_revenue = revenue


# ============ PHASE 5: PERCENTAGE CALCULATIONS ============

class TestPhase5Percentages:
    """Verify percentage calculations."""

    def test_revenue_pct_calculation(self, classification_rows):
        """Revenue percentage calculated correctly."""
        print("\n" + "="*50 + "\nPHASE 5: Percentages\n" + "="*50)
        total_revenue = sum(float(r[3]) for r in classification_rows)
        for r in classification_rows[:20]:
            revenue = float(r[3])
            pct = float(r[8])
            expected = round(100.0 * revenue / total_revenue, 2)
            assert abs(pct - expected) < 0.1, f"Revenue pct mismatch: {pct} != {expected}"

    def test_revenue_pct_sums_to_100(self, classification_rows):
        """Revenue percentages sum to 100."""
        total_pct = sum(float(r[8]) for r in classification_rows)
        assert abs(total_pct - 100) < 1.0, f"Revenue pct sum is {total_pct}"

    def test_cumulative_pct_increases(self, classification_rows):
        """Cumulative percentage increases monotonically."""
        prev_cum = 0
        for r in classification_rows:
            cum = float(r[10])
            assert cum >= prev_cum, f"Cumulative decreased: {cum} < {prev_cum}"
            prev_cum = cum

    def test_cumulative_ends_at_100(self, classification_rows):
        """Final cumulative percentage is ~100."""
        last_cum = float(classification_rows[-1][10])
        assert abs(last_cum - 100) < 0.1, f"Final cumulative is {last_cum}"


# ============ PHASE 6: CUMULATIVE CALCULATIONS ============

class TestPhase6Cumulative:
    """Verify cumulative calculations."""

    def test_cumulative_revenue_calculation(self, classification_rows):
        """Cumulative revenue calculated correctly."""
        print("\n" + "="*50 + "\nPHASE 6: Cumulative\n" + "="*50)
        running_total = 0
        for r in classification_rows[:20]:
            revenue = float(r[3])
            cumulative = float(r[9])
            running_total += revenue
            assert abs(cumulative - running_total) < 0.1, f"Cumulative mismatch: {cumulative} != {running_total}"

    def test_cumulative_pct_calculation(self, classification_rows):
        """Cumulative percentage matches cumulative revenue."""
        total_revenue = sum(float(r[3]) for r in classification_rows)
        for r in classification_rows[:20]:
            cum_revenue = float(r[9])
            cum_pct = float(r[10])
            expected_pct = round(100.0 * cum_revenue / total_revenue, 2)
            assert abs(cum_pct - expected_pct) < 0.1, f"Cumulative pct mismatch"


# ============ PHASE 7: ABC CLASSIFICATION LOGIC ============

class TestPhase7ABCLogic:
    """Verify ABC classification thresholds."""

    def test_class_a_threshold(self, classification_rows):
        """Class A products have cumulative <= 80%."""
        print("\n" + "="*50 + "\nPHASE 7: ABC Logic\n" + "="*50)
        for r in classification_rows:
            if r[13] == 'A':
                cum_pct = float(r[10])
                assert cum_pct <= 80.01, f"Class A with cumulative {cum_pct} > 80%"

    def test_class_b_threshold(self, classification_rows):
        """Class B products have cumulative > 80% and <= 95%."""
        for r in classification_rows:
            if r[13] == 'B':
                cum_pct = float(r[10])
                # B class should be between 80% and 95%
                assert cum_pct > 79.99, f"Class B with cumulative {cum_pct} <= 80%"
                assert cum_pct <= 95.01, f"Class B with cumulative {cum_pct} > 95%"

    def test_class_c_threshold(self, classification_rows):
        """Class C products have cumulative > 95%."""
        for r in classification_rows:
            if r[13] == 'C':
                cum_pct = float(r[10])
                assert cum_pct > 94.99, f"Class C with cumulative {cum_pct} <= 95%"

    def test_abc_transition(self, classification_rows):
        """ABC classes transition correctly (A -> B -> C)."""
        seen_b = False
        seen_c = False
        for r in classification_rows:
            abc = r[13]
            if abc == 'B':
                seen_b = True
            if abc == 'C':
                seen_c = True
            # Once we see B, we shouldn't see A again
            if seen_b:
                assert abc != 'A', "Class A found after B"
            # Once we see C, we shouldn't see A or B
            if seen_c:
                assert abc == 'C', f"Class {abc} found after C"


# ============ PHASE 8: PARETO ANALYSIS ============

class TestPhase8Pareto:
    """Verify Pareto (80/20) analysis."""

    def test_pareto_products_in_top_20_pct(self, classification_rows):
        """Pareto products are in top 20% by count."""
        print("\n" + "="*50 + "\nPHASE 8: Pareto\n" + "="*50)
        total_products = len(classification_rows)
        top_20_pct_count = int(total_products * 0.2) + 1

        for i, r in enumerate(classification_rows):
            is_pareto = is_truthy(r[14])
            if is_pareto:
                # Product count rank should be in top 20%
                assert i < top_20_pct_count, f"Pareto product at position {i+1} > top 20%"

    def test_pareto_products_contribute_to_80(self, classification_rows):
        """Pareto products are in the 80% cumulative revenue band."""
        for r in classification_rows:
            is_pareto = is_truthy(r[14])
            cum_pct = float(r[10])
            if is_pareto:
                assert cum_pct <= 80.01, f"Pareto product with cumulative {cum_pct} > 80%"


# ============ PHASE 9: AVERAGE CALCULATIONS ============

class TestPhase9Averages:
    """Verify average calculations."""

    def test_avg_order_value_calculation(self, classification_rows):
        """Average order value = total_revenue / order_count."""
        print("\n" + "="*50 + "\nPHASE 9: Averages\n" + "="*50)
        for r in classification_rows[:20]:
            revenue = float(r[3])
            order_count = r[5]
            avg_ov = float(r[7])
            expected = round(revenue / order_count, 2)
            assert abs(avg_ov - expected) < 0.1, f"Avg order value mismatch: {avg_ov} != {expected}"

    def test_avg_monthly_revenue_calculation(self, classification_rows):
        """Average monthly revenue = total_revenue / months_active."""
        for r in classification_rows[:20]:
            revenue = float(r[3])
            months = r[18]
            avg_monthly = float(r[15])
            expected = round(revenue / months, 2)
            assert abs(avg_monthly - expected) < 0.1, f"Avg monthly mismatch"


# ============ PHASE 10: VELOCITY CLASSIFICATION ============

class TestPhase10Velocity:
    """Verify velocity classification."""

    def test_velocity_logic(self, classification_rows):
        """Velocity classification matches avg_monthly_revenue."""
        print("\n" + "="*50 + "\nPHASE 10: Velocity\n" + "="*50)
        overall_avg = sum(float(r[15]) for r in classification_rows) / len(classification_rows)

        for r in classification_rows[:50]:
            avg_monthly = float(r[15])
            velocity = r[19]

            if avg_monthly > overall_avg * 1.5:
                expected = 'High'
            elif avg_monthly < overall_avg * 0.5:
                expected = 'Low'
            else:
                expected = 'Medium'

            assert velocity == expected, f"Velocity mismatch: {velocity} != {expected}"


# ============ PHASE 11: MONTH FORMAT ============

class TestPhase11MonthFormat:
    """Verify month format."""

    def test_first_sale_month_format(self, classification_rows):
        """First sale month is YYYY-MM format."""
        print("\n" + "="*50 + "\nPHASE 11: Month Format\n" + "="*50)
        for r in classification_rows[:20]:
            assert re.match(r'^\d{4}-\d{2}$', r[16]), f"Invalid first_sale_month: {r[16]}"

    def test_last_sale_month_format(self, classification_rows):
        """Last sale month is YYYY-MM format."""
        for r in classification_rows[:20]:
            assert re.match(r'^\d{4}-\d{2}$', r[17]), f"Invalid last_sale_month: {r[17]}"

    def test_first_before_last(self, classification_rows):
        """First sale month <= last sale month."""
        for r in classification_rows:
            first = r[16]
            last = r[17]
            assert first <= last, f"First {first} > Last {last}"


# ============ PHASE 12: SUMMARY CONSISTENCY ============

class TestPhase12SummaryConsistency:
    """Verify summary table consistency with classification."""

    def test_product_count_matches(self, summary_rows, classification_rows):
        """Summary product counts match classification."""
        print("\n" + "="*50 + "\nPHASE 12: Summary Consistency\n" + "="*50)
        from collections import Counter
        class_counts = Counter(r[13] for r in classification_rows)

        for r in summary_rows:
            abc_class = r[0]
            count = r[1]
            assert count == class_counts[abc_class], f"Class {abc_class} count mismatch"

    def test_total_revenue_matches(self, summary_rows, classification_rows):
        """Summary total revenue matches classification."""
        class_revenue = {}
        for r in classification_rows:
            abc = r[13]
            rev = float(r[3])
            class_revenue[abc] = class_revenue.get(abc, 0) + rev

        for r in summary_rows:
            abc = r[0]
            summary_rev = float(r[3])
            expected = round(class_revenue[abc], 2)
            assert abs(summary_rev - expected) < 1.0, f"Class {abc} revenue mismatch"

    def test_product_pct_sums_to_100(self, summary_rows):
        """Summary product percentages sum to 100."""
        total = sum(float(r[2]) for r in summary_rows)
        assert abs(total - 100) < 0.5, f"Product pct sum is {total}"

    def test_revenue_pct_sums_to_100(self, summary_rows):
        """Summary revenue percentages sum to 100."""
        total = sum(float(r[4]) for r in summary_rows)
        assert abs(total - 100) < 0.5, f"Revenue pct sum is {total}"


# ============ PHASE 13: CATEGORY BREAKDOWN CONSISTENCY ============

class TestPhase13CategoryConsistency:
    """Verify category breakdown consistency."""

    def test_class_counts_sum(self, category_rows):
        """A + B + C counts equal total products per category."""
        print("\n" + "="*50 + "\nPHASE 13: Category Consistency\n" + "="*50)
        for r in category_rows:
            total = r[1]
            a_count = r[3]
            b_count = r[4]
            c_count = r[5]
            assert a_count + b_count + c_count == total, f"Class counts don't sum to total"

    def test_class_percentages_sum(self, category_rows):
        """A + B + C percentages sum to 100."""
        for r in category_rows:
            a_pct = float(r[6])
            b_pct = float(r[7])
            c_pct = float(r[8])
            total = a_pct + b_pct + c_pct
            assert abs(total - 100) < 0.5, f"Class percentages sum to {total}"

    def test_revenue_percentages_sum(self, category_rows):
        """Revenue percentages sum to 100."""
        for r in category_rows:
            a_rev_pct = float(r[12])
            b_rev_pct = float(r[13])
            c_rev_pct = float(r[14])
            total = a_rev_pct + b_rev_pct + c_rev_pct
            assert abs(total - 100) < 0.5, f"Revenue percentages sum to {total}"

    def test_concentration_logic(self, category_rows):
        """Concentration classification matches revenue percentages."""
        for r in category_rows:
            a_rev_pct = float(r[12])
            c_rev_pct = float(r[14])
            concentration = r[15]

            if a_rev_pct >= 70:
                expected = 'A-Heavy'
            elif c_rev_pct >= 30:
                expected = 'C-Heavy'
            else:
                expected = 'Balanced'

            assert concentration == expected, f"Concentration mismatch: {concentration} != {expected}"


# ============ PHASE 14: MATERIALIZATION ============

class TestPhase14Materialization:
    """Verify materialization types."""

    def test_classification_is_table(self, dbt_run):
        """abc_classification is a table."""
        print("\n" + "="*50 + "\nPHASE 14: Materialization\n" + "="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'abc_classification'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()

    def test_summary_is_table(self, dbt_run):
        """abc_summary is a table."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'abc_summary'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()

    def test_category_is_table(self, dbt_run):
        """abc_category_breakdown is a table."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, """
                SELECT table_type FROM information_schema.tables
                WHERE LOWER(table_name) = 'abc_category_breakdown'
            """)
            if result:
                assert result[0][0] in ('BASE TABLE', 'TABLE')
        finally:
            conn.close()


# ============ PHASE 15: UNIQUE PRODUCTS ============

class TestPhase15UniqueProducts:
    """Verify product uniqueness."""

    def test_unique_product_ids(self, classification_rows):
        """No duplicate product IDs in classification."""
        print("\n" + "="*50 + "\nPHASE 15: Unique Products\n" + "="*50)
        product_ids = [r[0] for r in classification_rows]
        assert len(product_ids) == len(set(product_ids)), "Duplicate product IDs found"


# ============ PHASE 16: RANK CONSISTENCY ============

class TestPhase16RankConsistency:
    """Verify ranking consistency."""

    def test_revenue_rank_no_gaps(self, classification_rows):
        """Revenue ranks have no gaps (dense rank)."""
        print("\n" + "="*50 + "\nPHASE 16: Rank Consistency\n" + "="*50)
        ranks = [r[11] for r in classification_rows]
        unique_ranks = sorted(set(ranks))

        # Check that ranks are consecutive when deduplicated
        for i, rank in enumerate(unique_ranks):
            assert rank == i + 1, f"Gap in revenue ranks at {rank}"

    def test_quantity_rank_no_gaps(self, classification_rows):
        """Quantity ranks have no gaps (dense rank)."""
        ranks = [r[12] for r in classification_rows]
        unique_ranks = sorted(set(ranks))

        for i, rank in enumerate(unique_ranks):
            assert rank == i + 1, f"Gap in quantity ranks at {rank}"


# ============ PHASE 17: IDEMPOTENCY ============

class TestPhase17Idempotency:
    """Verify idempotency."""

    def test_idempotency(self, classification_rows):
        """Re-running dbt produces identical results."""
        print("\n" + "="*50 + "\nPHASE 17: Idempotency\n" + "="*50)
        original_count = len(classification_rows)
        original_first = classification_rows[0] if classification_rows else None
        original_last = classification_rows[-1] if classification_rows else None

        run_dbt_pipeline()

        new_rows = query_abc_classification()
        assert len(new_rows) == original_count, f"Row count changed"
        if original_first:
            assert new_rows[0] == original_first, "First row changed"
        if original_last:
            assert new_rows[-1] == original_last, "Last row changed"
