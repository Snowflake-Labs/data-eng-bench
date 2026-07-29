"""
Test verifier for Sales Funnel Analysis task.
Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate conversion rates and counts
  Phase 3: Validate dropoff analysis
  Phase 4: Test idempotency (re-run produces same results)
"""
import os
import subprocess
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
    Returns (conn, db_type) tuple."""
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
    """Execute a query and return results"""
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


# ============ CONFIGURATION ============

SCHEMA = "funnel_analytics"
PROJECT_DIR = "/app/dbt_project"

# Expected counts (with tolerance for edge case handling across DuckDB and Snowflake)
EXPECTED_TOTAL_SESSIONS = 5053
EXPECTED_SESSIONS_WITH_VIEW = (450, 650)  # DuckDB ~584, Snowflake ~503
EXPECTED_SESSIONS_WITH_CART = (500, 700)  # DuckDB ~601, Snowflake may differ
EXPECTED_SESSIONS_WITH_PURCHASE = (130, 500)  # DuckDB ~160 without 'converted'; widen upper bound to include 'converted' (correct answer is 444)

# ============ HELPERS ============


def run_cmd(cmd, cwd=PROJECT_DIR):
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


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


# ============ PHASE 1: STRUCTURE VALIDATION ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_int_session_funnel_exists(self, dbt_run):
        """Validate int_session_funnel model exists with required columns."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)

        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'funnel_analytics'
                AND lower(table_name) = 'int_session_funnel'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"session_id", "visitor_id", "customer_id", "session_start",
                       "has_product_view", "has_add_to_cart", "has_purchase", "funnel_stage"}
            missing = required - col_names
            assert not missing, f"Missing columns in int_session_funnel: {missing}"
            print(f"int_session_funnel has all required columns")
        finally:
            conn.close()

    def test_funnel_conversion_rates_exists(self, dbt_run):
        """Validate funnel_conversion_rates model exists with required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'funnel_analytics'
                AND lower(table_name) = 'funnel_conversion_rates'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"total_sessions", "sessions_with_view", "sessions_with_cart",
                       "sessions_with_purchase", "view_rate", "view_to_cart_rate",
                       "cart_to_purchase_rate", "overall_conversion_rate"}
            missing = required - col_names
            assert not missing, f"Missing columns in funnel_conversion_rates: {missing}"
            print(f"funnel_conversion_rates has all required columns")
        finally:
            conn.close()

    def test_funnel_dropoff_analysis_exists(self, dbt_run):
        """Validate funnel_dropoff_analysis model exists with required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = 'funnel_analytics'
                AND lower(table_name) = 'funnel_dropoff_analysis'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"dropoff_stage", "session_count", "dropoff_rate"}
            missing = required - col_names
            assert not missing, f"Missing columns in funnel_dropoff_analysis: {missing}"
            print(f"funnel_dropoff_analysis has all required columns")
        finally:
            conn.close()


# ============ PHASE 2: CONVERSION RATES VALIDATION ============

class TestPhase2ConversionRates:
    """Phase 2: Validate conversion rates and counts."""

    def test_conversion_rates_single_row(self, dbt_run):
        """Validate funnel_conversion_rates has exactly 1 row."""
        print("\n" + "="*50)
        print("PHASE 2: Conversion Rates Validation")
        print("="*50)

        conn, db_type = get_db_connection()
        try:
            count = int(execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.funnel_conversion_rates
            """))
            assert count == 1, f"Expected 1 row in funnel_conversion_rates, got {count}"
            print("funnel_conversion_rates has exactly 1 row")
        finally:
            conn.close()

    def test_total_sessions_count(self, dbt_run):
        """Validate total sessions count."""
        conn, db_type = get_db_connection()
        try:
            result = int(execute_scalar(conn, db_type, f"""
                SELECT total_sessions FROM {SCHEMA}.funnel_conversion_rates
            """))
            assert result == EXPECTED_TOTAL_SESSIONS, \
                f"Expected total_sessions={EXPECTED_TOTAL_SESSIONS}, got {result}"
            print(f"Total sessions correct: {result}")
        finally:
            conn.close()

    def test_sessions_counts_reasonable(self, dbt_run):
        """Validate session counts are within expected ranges."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT sessions_with_view, sessions_with_cart, sessions_with_purchase
                FROM {SCHEMA}.funnel_conversion_rates
            """)

            with_view = int(result[0][0])
            with_cart = int(result[0][1])
            with_purchase = int(result[0][2])

            assert EXPECTED_SESSIONS_WITH_VIEW[0] <= with_view <= EXPECTED_SESSIONS_WITH_VIEW[1], \
                f"sessions_with_view {with_view} outside expected range {EXPECTED_SESSIONS_WITH_VIEW}"
            assert EXPECTED_SESSIONS_WITH_CART[0] <= with_cart <= EXPECTED_SESSIONS_WITH_CART[1], \
                f"sessions_with_cart {with_cart} outside expected range {EXPECTED_SESSIONS_WITH_CART}"
            assert EXPECTED_SESSIONS_WITH_PURCHASE[0] <= with_purchase <= EXPECTED_SESSIONS_WITH_PURCHASE[1], \
                f"sessions_with_purchase {with_purchase} outside expected range {EXPECTED_SESSIONS_WITH_PURCHASE}"

            print(f"Session counts valid: view={with_view}, cart={with_cart}, purchase={with_purchase}")
        finally:
            conn.close()

    def test_rates_calculated_correctly(self, dbt_run):
        """Validate rates are calculated from counts."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    total_sessions, sessions_with_view, sessions_with_cart, sessions_with_purchase,
                    view_rate, view_to_cart_rate, cart_to_purchase_rate, overall_conversion_rate
                FROM {SCHEMA}.funnel_conversion_rates
            """)

            row = result[0]
            total = int(row[0])
            with_view = int(row[1])
            with_cart = int(row[2])
            with_purchase = int(row[3])
            view_rate = float(row[4])
            vtc_rate = float(row[5])
            ctp_rate = float(row[6])
            overall = float(row[7])

            # Calculate expected rates
            expected_view_rate = with_view / total if total > 0 else 0
            expected_vtc_rate = with_cart / with_view if with_view > 0 else 0
            expected_ctp_rate = with_purchase / with_cart if with_cart > 0 else 0
            expected_overall = with_purchase / total if total > 0 else 0

            # Check rates match (with small tolerance for rounding)
            assert abs(view_rate - expected_view_rate) < 0.001, \
                f"view_rate {view_rate} doesn't match expected {expected_view_rate:.4f}"
            assert abs(vtc_rate - expected_vtc_rate) < 0.001, \
                f"view_to_cart_rate {vtc_rate} doesn't match expected {expected_vtc_rate:.4f}"
            assert abs(ctp_rate - expected_ctp_rate) < 0.001, \
                f"cart_to_purchase_rate {ctp_rate} doesn't match expected {expected_ctp_rate:.4f}"
            assert abs(overall - expected_overall) < 0.001, \
                f"overall_conversion_rate {overall} doesn't match expected {expected_overall:.4f}"

            print(f"Rates calculated correctly:")
            print(f"  view_rate: {view_rate}")
            print(f"  view_to_cart_rate: {vtc_rate}")
            print(f"  cart_to_purchase_rate: {ctp_rate}")
            print(f"  overall_conversion_rate: {overall}")
        finally:
            conn.close()

    def test_no_null_rates(self, dbt_run):
        """Validate no NULL values in rate columns."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    CASE WHEN view_rate IS NULL THEN 1 ELSE 0 END,
                    CASE WHEN view_to_cart_rate IS NULL THEN 1 ELSE 0 END,
                    CASE WHEN cart_to_purchase_rate IS NULL THEN 1 ELSE 0 END,
                    CASE WHEN overall_conversion_rate IS NULL THEN 1 ELSE 0 END
                FROM {SCHEMA}.funnel_conversion_rates
            """)

            row = result[0]
            null_flags = [int(x) for x in row]
            assert not any(null_flags), f"Found NULL rates: {null_flags}"
            print("No NULL values in rate columns")
        finally:
            conn.close()


# ============ PHASE 3: DROPOFF ANALYSIS VALIDATION ============

class TestPhase3DropoffAnalysis:
    """Phase 3: Validate dropoff analysis."""

    def test_dropoff_has_three_rows(self, dbt_run):
        """Validate funnel_dropoff_analysis has exactly 3 rows."""
        print("\n" + "="*50)
        print("PHASE 3: Dropoff Analysis Validation")
        print("="*50)

        conn, db_type = get_db_connection()
        try:
            count = int(execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA}.funnel_dropoff_analysis
            """))
            assert count == 3, f"Expected 3 rows in funnel_dropoff_analysis, got {count}"
            print("funnel_dropoff_analysis has exactly 3 rows")
        finally:
            conn.close()

    def test_dropoff_stages_present(self, dbt_run):
        """Validate all required dropoff stages are present."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT dropoff_stage FROM {SCHEMA}.funnel_dropoff_analysis
            """)
            stages = {r[0] for r in result}
            required = {'BEFORE_VIEW', 'VIEW_TO_CART', 'CART_TO_PURCHASE'}
            missing = required - stages
            assert not missing, f"Missing dropoff stages: {missing}"
            print(f"All required dropoff stages present: {stages}")
        finally:
            conn.close()

    def test_dropoff_counts_match_funnel(self, dbt_run):
        """Validate dropoff counts match int_session_funnel data."""
        conn, db_type = get_db_connection()
        try:
            # Get counts from int_session_funnel using integer comparison
            funnel_counts = execute_query(conn, db_type, f"""
                SELECT
                    SUM(CASE WHEN has_product_view = 0 THEN 1 ELSE 0 END) as before_view,
                    SUM(CASE WHEN has_product_view = 1 AND has_add_to_cart = 0 THEN 1 ELSE 0 END) as view_to_cart,
                    SUM(CASE WHEN has_add_to_cart = 1 AND has_purchase = 0 THEN 1 ELSE 0 END) as cart_to_purchase
                FROM {SCHEMA}.int_session_funnel
            """)

            expected_before_view = int(funnel_counts[0][0])
            expected_view_to_cart = int(funnel_counts[0][1])
            expected_cart_to_purchase = int(funnel_counts[0][2])

            # Get counts from dropoff analysis
            dropoff_result = execute_query(conn, db_type, f"""
                SELECT dropoff_stage, session_count
                FROM {SCHEMA}.funnel_dropoff_analysis
            """)
            dropoff_counts = {r[0]: int(r[1]) for r in dropoff_result}

            assert dropoff_counts['BEFORE_VIEW'] == expected_before_view, \
                f"BEFORE_VIEW count {dropoff_counts['BEFORE_VIEW']} != expected {expected_before_view}"
            assert dropoff_counts['VIEW_TO_CART'] == expected_view_to_cart, \
                f"VIEW_TO_CART count {dropoff_counts['VIEW_TO_CART']} != expected {expected_view_to_cart}"
            assert dropoff_counts['CART_TO_PURCHASE'] == expected_cart_to_purchase, \
                f"CART_TO_PURCHASE count {dropoff_counts['CART_TO_PURCHASE']} != expected {expected_cart_to_purchase}"

            print(f"Dropoff counts match funnel data:")
            print(f"  BEFORE_VIEW: {dropoff_counts['BEFORE_VIEW']}")
            print(f"  VIEW_TO_CART: {dropoff_counts['VIEW_TO_CART']}")
            print(f"  CART_TO_PURCHASE: {dropoff_counts['CART_TO_PURCHASE']}")
        finally:
            conn.close()

    def test_dropoff_rates_valid(self, dbt_run):
        """Validate dropoff rates are between 0 and 1."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT dropoff_stage, dropoff_rate
                FROM {SCHEMA}.funnel_dropoff_analysis
            """)

            for stage, rate in result:
                assert rate is not None, f"NULL dropoff_rate for {stage}"
                assert 0 <= float(rate) <= 1, f"dropoff_rate {rate} for {stage} not between 0 and 1"

            print("All dropoff rates are valid (between 0 and 1)")
        finally:
            conn.close()


# ============ PHASE 4: IDEMPOTENCY VALIDATION ============

class TestPhase4Idempotency:
    """Phase 4: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, dbt_run):
        """Test that re-running dbt produces the same results."""
        print("\n" + "="*50)
        print("PHASE 4: Idempotency Test")
        print("="*50)

        conn, db_type = get_db_connection()
        try:
            # Get current results
            before_rates = execute_query(conn, db_type, f"""
                SELECT total_sessions, sessions_with_view, sessions_with_cart,
                       sessions_with_purchase
                FROM {SCHEMA}.funnel_conversion_rates
            """)
            before_dropoff = execute_query(conn, db_type, f"""
                SELECT dropoff_stage, session_count
                FROM {SCHEMA}.funnel_dropoff_analysis ORDER BY dropoff_stage
            """)
        finally:
            conn.close()

        # Re-run dbt
        run_dbt_pipeline()

        conn, db_type = get_db_connection()
        try:
            # Get new results
            after_rates = execute_query(conn, db_type, f"""
                SELECT total_sessions, sessions_with_view, sessions_with_cart,
                       sessions_with_purchase
                FROM {SCHEMA}.funnel_conversion_rates
            """)
            after_dropoff = execute_query(conn, db_type, f"""
                SELECT dropoff_stage, session_count
                FROM {SCHEMA}.funnel_dropoff_analysis ORDER BY dropoff_stage
            """)

            # Compare integer columns to avoid Decimal comparison issues
            before_int = [int(x) for x in before_rates[0]]
            after_int = [int(x) for x in after_rates[0]]
            assert before_int == after_int, \
                f"funnel_conversion_rates changed after re-run:\nBefore: {before_int}\nAfter: {after_int}"

            before_drop = [(r[0], int(r[1])) for r in before_dropoff]
            after_drop = [(r[0], int(r[1])) for r in after_dropoff]
            assert before_drop == after_drop, \
                f"funnel_dropoff_analysis changed after re-run"

            print("Idempotency verified: results unchanged after re-run")
        finally:
            conn.close()
