"""
Test verifier for Customer Order Interval Metrics task.
Multi-phase testing with strict validation:
  Phase 1: Validate model structure
  Phase 2: Validate column order and data types
  Phase 3: Validate calculations and NULL handling
  Phase 4: Spot-check specific customers (hidden ground truth)
  Phase 5: Test idempotency
"""
import subprocess
import pytest
import os

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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ CONSTANTS ============

def _get_model_schema():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'main_order_analytics'


MODEL_SCHEMA = _get_model_schema()

# Required columns in exact order (25 columns)
REQUIRED_COLUMNS_ORDERED = [
    "customer_id", "total_orders", "first_order_date", "last_order_date",
    "customer_lifespan_days", "total_revenue", "avg_order_value",
    "avg_days_between_orders", "min_days_between_orders", "max_days_between_orders",
    "std_dev_days", "ordering_frequency", "is_repeat_customer", "days_since_last_order",
    "customer_tier", "churn_risk", "purchase_consistency", "customer_value_score", "customer_segment",
    "order_acceleration", "monthly_order_rate", "spending_trend", "loyalty_index",
    "engagement_momentum", "lifecycle_stage"
]

# Valid ordering frequency values
VALID_FREQUENCIES = {'One-time', 'Frequent', 'Regular', 'Occasional', 'Rare'}

# Valid customer tier values
VALID_TIERS = {'Platinum', 'Gold', 'Silver', 'Bronze'}

# Valid churn risk values
VALID_CHURN_RISKS = {'High', 'Medium', 'Low'}

# Valid purchase consistency values (can also be NULL)
VALID_CONSISTENCY = {'High', 'Medium', 'Low'}

# Valid customer segment values
VALID_SEGMENTS = {'Champion', 'Loyal', 'Potential', 'At Risk', 'Hibernating'}

# Valid order acceleration values (can also be NULL)
VALID_ACCELERATION = {'Accelerating', 'Stable', 'Decelerating'}

# Valid spending trend values (can also be NULL)
VALID_SPENDING_TREND = {'Increasing', 'Stable', 'Decreasing'}

# Valid engagement momentum values
VALID_MOMENTUM = {'Accelerating', 'Stable', 'Decelerating', 'Emerging', 'Inactive'}

# Valid lifecycle stage values
VALID_LIFECYCLE = {'New', 'Growing', 'Mature', 'Declining', 'Churned'}

# Reference date for days_since_last_order calculation
REFERENCE_DATE = '2024-12-31'

# Expected customer counts
EXPECTED_TOTAL_CUSTOMERS = 143
EXPECTED_FREQUENCY_COUNTS = {
    'One-time': 102,
    'Regular': 20,
    'Occasional': 11,
    'Frequent': 7,
    'Rare': 3
}

# Expected tier distribution (NTILE-based)
EXPECTED_TIER_COUNTS = {
    'Platinum': 35,
    'Gold': 36,
    'Silver': 36,
    'Bronze': 36
}

# Expected churn risk distribution
EXPECTED_CHURN_RISK_COUNTS = {
    'High': 79,
    'Medium': 11,
    'Low': 53
}

# Expected purchase consistency distribution
EXPECTED_CONSISTENCY_COUNTS = {
    'High': 4,
    'Medium': 11,
    'Low': 6,
    None: 122  # Customers with fewer than 3 orders
}

# Expected customer segment distribution
EXPECTED_SEGMENT_COUNTS = {
    'Champion': 14,
    'Loyal': 27,
    'Potential': 48,
    'At Risk': 46,
    'Hibernating': 8
}

# Spot check customers: (customer_id, total_orders, total_revenue, ordering_frequency, is_repeat, tier, churn_risk, consistency, value_score, segment, acceleration, monthly_rate, spending_trend, loyalty_index, momentum, lifecycle)
SPOT_CHECK_CUSTOMERS = [
    # Top customer by revenue - frequent buyer with 56 orders, Champion
    ('05e238d5-82ac-4683-baa3-b649026efd25', 56, 22021.20, 'Frequent', 'Y', 'Platinum', 'Low', 'Low', 100, 'Champion', 'Accelerating', 5.0, 'Increasing', 80, 'Accelerating', 'Mature'),
    # Second highest revenue - frequent buyer with 36 orders, Champion
    ('414ac645-cc7b-4613-9d3a-9b3e974d3c7a', 36, 14683.77, 'Frequent', 'Y', 'Platinum', 'Low', 'Medium', 100, 'Champion', 'Accelerating', 3.22, 'Increasing', 90, 'Accelerating', 'Mature'),
    # One-time high-value customer with good recency - Loyal
    ('ef655ed3-609d-429c-9166-e43ff2feb2c3', 1, 2530.18, 'One-time', 'N', 'Platinum', 'Low', None, 71, 'Loyal', None, 1.0, None, 5, 'Emerging', 'New'),
    # Customer with Medium churn risk - Champion
    ('c955ecd4-d5af-4e0b-96d1-3f2283e8801e', 8, 2367.67, 'Regular', 'Y', 'Platinum', 'Medium', 'Medium', 83, 'Champion', 'Accelerating', 1.2, 'Stable', 68, 'Accelerating', 'Declining'),
    # Rare customer with High churn risk - Potential
    ('21a0f0ca-80a0-46a5-8bf2-6e810172f0fb', 2, 1252.21, 'Rare', 'Y', 'Platinum', 'High', None, 58, 'Potential', None, 0.27, 'Decreasing', 37, 'Inactive', 'Churned'),
]

# Top customer detailed check
TOP_CUSTOMER = {
    'customer_id': '05e238d5-82ac-4683-baa3-b649026efd25',
    'total_orders': 56,
    'first_order_date': '2024-01-29',
    'last_order_date': '2024-12-30',
    'customer_lifespan_days': 336,
    'total_revenue': 22021.20,
    'avg_days_between_orders': 6.11,
    'min_days_between_orders': 0,
    'max_days_between_orders': 37,
    'ordering_frequency': 'Frequent',
    'is_repeat_customer': 'Y',
    'days_since_last_order': 1,
    'customer_tier': 'Platinum',
    'churn_risk': 'Low',
    'purchase_consistency': 'Low',
    'customer_value_score': 100,
    'customer_segment': 'Champion',
    'order_acceleration': 'Accelerating',
    'spending_trend': 'Increasing',
    'engagement_momentum': 'Accelerating',
    'lifecycle_stage': 'Mature'
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
    """Run dbt run."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    result = run_cmd("dbt run --select stg_orders__timeline int_customer_order_gaps customer_order_intervals")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_customer_intervals():
    """Query customer_order_intervals model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                customer_id,
                total_orders,
                first_order_date,
                last_order_date,
                customer_lifespan_days,
                total_revenue,
                avg_order_value,
                avg_days_between_orders,
                min_days_between_orders,
                max_days_between_orders,
                std_dev_days,
                ordering_frequency,
                is_repeat_customer,
                days_since_last_order,
                customer_tier,
                churn_risk,
                purchase_consistency,
                customer_value_score,
                customer_segment,
                order_acceleration,
                monthly_order_rate,
                spending_trend,
                loyalty_index,
                engagement_momentum,
                lifecycle_stage
            FROM {MODEL_SCHEMA}.customer_order_intervals
            ORDER BY total_revenue DESC
        """)
        return rows
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def customer_rows(dbt_run):
    """Fixture that provides customer_order_intervals rows after dbt run."""
    return query_customer_intervals()


# ============ PHASE 1: STRUCTURE VALIDATION ============

class TestPhase1Structure:
    """Phase 1: Validate model structure."""

    def test_staging_model_exists(self, dbt_run):
        """Validate staging model exists."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_name) = 'stg_orders__timeline'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}', 'main_staging')
            """)
            assert int(result) > 0, "Staging model stg_orders__timeline not found"
        finally:
            conn.close()

    def test_intermediate_model_exists(self, dbt_run):
        """Validate intermediate model exists."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_name) = 'int_customer_order_gaps'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}', 'main_intermediate')
            """)
            assert int(result) > 0, "Intermediate model int_customer_order_gaps not found"
        finally:
            conn.close()

    def test_mart_model_exists(self, dbt_run):
        """Validate mart model exists."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE lower(table_name) = 'customer_order_intervals'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}')
            """)
            assert int(result) > 0, "Model customer_order_intervals not found"
        finally:
            conn.close()

    def test_mart_is_table_not_view(self, dbt_run):
        """Validate mart model is materialized as TABLE."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT table_type FROM information_schema.tables
                WHERE lower(table_name) = 'customer_order_intervals'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}')
            """)
            assert len(result) > 0, "Model not found"
            table_type = result[0][0].upper()
            assert 'VIEW' not in table_type, f"Must be TABLE, got {table_type}"
        finally:
            conn.close()

    def test_intermediate_has_order_half_column(self, dbt_run):
        """Validate intermediate model has order_half column."""
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM information_schema.columns
                WHERE lower(table_name) = 'int_customer_order_gaps'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}', 'main_intermediate')
                AND lower(column_name) = 'order_half'
            """)
            assert int(result) > 0, "Intermediate model missing order_half column"
        finally:
            conn.close()


# ============ PHASE 2: COLUMN VALIDATION ============

class TestPhase2Columns:
    """Phase 2: Validate column order and data types."""

    def test_column_count(self, dbt_run):
        """Validate exactly 25 columns exist."""
        print("\n" + "="*50)
        print("PHASE 2: Column Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM information_schema.columns
                WHERE lower(table_name) = 'customer_order_intervals'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}')
            """)
            assert int(result) == 25, f"Expected 25 columns, got {result}"
        finally:
            conn.close()

    def test_column_order(self, dbt_run):
        """Validate columns appear in exact order."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_name) = 'customer_order_intervals'
                AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}')
                ORDER BY ordinal_position
            """)
            actual_cols = [c[0].lower() for c in cols]
            expected_cols = [c.lower() for c in REQUIRED_COLUMNS_ORDERED]

            assert actual_cols == expected_cols, \
                f"Column order mismatch.\nExpected: {expected_cols}\nActual: {actual_cols}"
        finally:
            conn.close()

    def test_date_columns_are_date_type(self, dbt_run):
        """Validate date columns are DATE type."""
        conn, db_type = get_db_connection()
        try:
            for col in ['first_order_date', 'last_order_date']:
                result = execute_query(conn, db_type, f"""
                    SELECT data_type
                    FROM information_schema.columns
                    WHERE lower(table_name) = 'customer_order_intervals'
                    AND lower(table_schema) IN ('main', '{MODEL_SCHEMA.lower()}')
                    AND lower(column_name) = '{col}'
                """)
                assert len(result) > 0, f"Column {col} not found"
                data_type = result[0][0].upper()
                assert 'DATE' in data_type and 'TIME' not in data_type, \
                    f"{col} must be DATE, got {data_type}"
        finally:
            conn.close()


# ============ PHASE 3: DATA VALIDATION ============

class TestPhase3Data:
    """Phase 3: Validate calculations and NULL handling."""

    def test_has_customers(self, customer_rows):
        """Validate we have customer data."""
        print("\n" + "="*50)
        print("PHASE 3: Data Validation")
        print("="*50)
        assert len(customer_rows) > 0, "No customer data found"
        print(f"Found {len(customer_rows)} customers")

    def test_total_orders_positive(self, customer_rows):
        """Validate total_orders is positive for all customers."""
        for row in customer_rows:
            assert int(row[1]) > 0, f"Customer {row[0]}: total_orders must be positive, got {row[1]}"

    def test_lifespan_zero_for_single_order(self, customer_rows):
        """Validate customer_lifespan_days is 0 for single-order customers."""
        for row in customer_rows:
            if int(row[1]) == 1:  # total_orders == 1
                assert int(row[4]) == 0, \
                    f"Customer {row[0]}: single-order customer should have lifespan 0, got {row[4]}"

    def test_lifespan_positive_for_repeat(self, customer_rows):
        """Validate customer_lifespan_days is >= 0 for repeat customers."""
        for row in customer_rows:
            if int(row[1]) > 1:  # total_orders > 1
                assert int(row[4]) >= 0, \
                    f"Customer {row[0]}: repeat customer should have lifespan >= 0, got {row[4]}"

    def test_avg_order_value_calculation(self, customer_rows):
        """Validate avg_order_value = total_revenue / total_orders."""
        for row in customer_rows:
            expected_avg = round(float(row[5]) / int(row[1]), 2)
            actual_avg = float(row[6])
            assert abs(actual_avg - expected_avg) < 0.1, \
                f"Customer {row[0]}: avg_order_value mismatch, expected {expected_avg}, got {actual_avg}"

    def test_null_avg_days_for_single_order(self, customer_rows):
        """Validate avg_days_between_orders is NULL for single-order customers."""
        for row in customer_rows:
            if int(row[1]) == 1:  # total_orders == 1
                assert row[7] is None, \
                    f"Customer {row[0]}: single-order customer should have NULL avg_days_between_orders"

    def test_null_min_max_days_for_single_order(self, customer_rows):
        """Validate min/max_days_between_orders is NULL for single-order customers."""
        for row in customer_rows:
            if int(row[1]) == 1:  # total_orders == 1
                assert row[8] is None, \
                    f"Customer {row[0]}: single-order should have NULL min_days_between_orders"
                assert row[9] is None, \
                    f"Customer {row[0]}: single-order should have NULL max_days_between_orders"

    def test_null_std_dev_for_less_than_3_orders(self, customer_rows):
        """Validate std_dev_days is NULL for customers with fewer than 3 orders."""
        for row in customer_rows:
            if int(row[1]) < 3:  # total_orders < 3
                assert row[10] is None, \
                    f"Customer {row[0]}: customers with <3 orders should have NULL std_dev_days"

    def test_ordering_frequency_valid_values(self, customer_rows):
        """Validate ordering_frequency is one of the valid values."""
        for row in customer_rows:
            freq = row[11]
            assert freq in VALID_FREQUENCIES, \
                f"Customer {row[0]}: invalid ordering_frequency '{freq}'. Must be one of {VALID_FREQUENCIES}"

    def test_ordering_frequency_onetime(self, customer_rows):
        """Validate One-time frequency for single-order customers."""
        for row in customer_rows:
            if int(row[1]) == 1:  # total_orders == 1
                assert row[11] == 'One-time', \
                    f"Customer {row[0]}: single-order customer should be 'One-time', got '{row[11]}'"

    def test_ordering_frequency_logic(self, customer_rows):
        """Validate ordering_frequency classification logic."""
        for row in customer_rows:
            if int(row[1]) > 1 and row[7] is not None:  # Has avg_days_between_orders
                avg_days = float(row[7])
                freq = row[11]

                if avg_days < 30:
                    expected = 'Frequent'
                elif avg_days < 90:
                    expected = 'Regular'
                elif avg_days < 180:
                    expected = 'Occasional'
                else:
                    expected = 'Rare'

                assert freq == expected, \
                    f"Customer {row[0]}: avg_days={avg_days}, expected '{expected}', got '{freq}'"

    def test_is_repeat_customer_values(self, customer_rows):
        """Validate is_repeat_customer is exactly 'Y' or 'N'."""
        for row in customer_rows:
            is_repeat = row[12]
            assert is_repeat in ('Y', 'N'), \
                f"Customer {row[0]}: is_repeat_customer must be 'Y' or 'N', got '{is_repeat}'"

    def test_is_repeat_customer_logic(self, customer_rows):
        """Validate is_repeat_customer matches total_orders."""
        for row in customer_rows:
            total_orders = int(row[1])
            is_repeat = row[12]

            if total_orders > 1:
                assert is_repeat == 'Y', \
                    f"Customer {row[0]}: with {total_orders} orders should have is_repeat_customer='Y'"
            else:
                assert is_repeat == 'N', \
                    f"Customer {row[0]}: with {total_orders} order should have is_repeat_customer='N'"

    def test_days_since_last_order_positive(self, customer_rows):
        """Validate days_since_last_order is non-negative."""
        for row in customer_rows:
            days_since = int(row[13])
            assert days_since >= 0, \
                f"Customer {row[0]}: days_since_last_order must be >= 0, got {days_since}"

    def test_days_since_last_order_calculation(self, customer_rows):
        """Validate days_since_last_order is calculated from reference date."""
        from datetime import date
        ref_date = date(2024, 12, 31)
        for row in customer_rows:
            last_order = row[3]
            # Handle Snowflake returning datetime or date
            if hasattr(last_order, 'date'):
                last_order = last_order.date()
            expected_days = (ref_date - last_order).days
            actual_days = int(row[13])
            assert actual_days == expected_days, \
                f"Customer {row[0]}: days_since_last_order expected {expected_days}, got {actual_days}"

    def test_min_max_consistency(self, customer_rows):
        """Validate min_days <= max_days for repeat customers."""
        for row in customer_rows:
            if int(row[1]) > 1:  # repeat customer
                min_days = row[8]
                max_days = row[9]
                if min_days is not None and max_days is not None:
                    assert int(min_days) <= int(max_days), \
                        f"Customer {row[0]}: min_days ({min_days}) > max_days ({max_days})"

    def test_first_order_before_last(self, customer_rows):
        """Validate first_order_date <= last_order_date."""
        for row in customer_rows:
            first = row[2]
            last = row[3]
            # Handle Snowflake returning datetime
            if hasattr(first, 'date'):
                first = first.date()
            if hasattr(last, 'date'):
                last = last.date()
            assert first <= last, \
                f"Customer {row[0]}: first_order_date ({first}) > last_order_date ({last})"

    def test_ordered_by_revenue_desc(self, customer_rows):
        """Validate results are ordered by total_revenue descending."""
        for i in range(1, len(customer_rows)):
            prev_revenue = float(customer_rows[i-1][5])
            curr_revenue = float(customer_rows[i][5])
            assert prev_revenue >= curr_revenue, \
                f"Results not ordered by revenue DESC at position {i}: {prev_revenue} < {curr_revenue}"

    def test_total_revenue_positive(self, customer_rows):
        """Validate total_revenue is positive."""
        for row in customer_rows:
            assert float(row[5]) > 0, \
                f"Customer {row[0]}: total_revenue must be positive, got {row[5]}"

    def test_customer_tier_valid_values(self, customer_rows):
        """Validate customer_tier is one of the valid values."""
        for row in customer_rows:
            tier = row[14]
            assert tier in VALID_TIERS, \
                f"Customer {row[0]}: invalid customer_tier '{tier}'. Must be one of {VALID_TIERS}"

    def test_churn_risk_valid_values(self, customer_rows):
        """Validate churn_risk is one of the valid values."""
        for row in customer_rows:
            risk = row[15]
            assert risk in VALID_CHURN_RISKS, \
                f"Customer {row[0]}: invalid churn_risk '{risk}'. Must be one of {VALID_CHURN_RISKS}"

    def test_purchase_consistency_valid_values(self, customer_rows):
        """Validate purchase_consistency is one of the valid values or NULL."""
        for row in customer_rows:
            consistency = row[16]
            if consistency is not None:
                assert consistency in VALID_CONSISTENCY, \
                    f"Customer {row[0]}: invalid purchase_consistency '{consistency}'. Must be one of {VALID_CONSISTENCY} or NULL"

    def test_churn_risk_logic_high_days(self, customer_rows):
        """Validate High churn risk for customers with days_since >= 120."""
        for row in customer_rows:
            days_since = int(row[13])
            churn_risk = row[15]
            if days_since >= 120:
                assert churn_risk == 'High', \
                    f"Customer {row[0]}: days_since={days_since} >= 120 should be High churn, got '{churn_risk}'"

    def test_churn_risk_logic_high_onetime(self, customer_rows):
        """Validate High churn risk for one-time buyers with days_since >= 60."""
        for row in customer_rows:
            total_orders = int(row[1])
            days_since = int(row[13])
            churn_risk = row[15]
            if days_since >= 60 and days_since < 120 and total_orders == 1:
                assert churn_risk == 'High', \
                    f"Customer {row[0]}: one-time buyer with days_since={days_since} >= 60 should be High churn, got '{churn_risk}'"

    def test_churn_risk_logic_medium(self, customer_rows):
        """Validate Medium churn risk for repeat customers with 60 <= days_since < 120."""
        for row in customer_rows:
            total_orders = int(row[1])
            days_since = int(row[13])
            churn_risk = row[15]
            if days_since >= 60 and days_since < 120 and total_orders > 1:
                assert churn_risk == 'Medium', \
                    f"Customer {row[0]}: repeat buyer with days_since={days_since} should be Medium churn, got '{churn_risk}'"

    def test_churn_risk_logic_low(self, customer_rows):
        """Validate Low churn risk for customers with days_since < 60."""
        for row in customer_rows:
            days_since = int(row[13])
            churn_risk = row[15]
            if days_since < 60:
                assert churn_risk == 'Low', \
                    f"Customer {row[0]}: days_since={days_since} < 60 should be Low churn, got '{churn_risk}'"

    def test_consistency_null_for_few_orders(self, customer_rows):
        """Validate purchase_consistency is NULL for customers with < 3 orders."""
        for row in customer_rows:
            total_orders = int(row[1])
            consistency = row[16]
            if total_orders < 3:
                assert consistency is None, \
                    f"Customer {row[0]}: with {total_orders} orders should have NULL consistency, got '{consistency}'"

    def test_consistency_not_null_for_3plus_orders(self, customer_rows):
        """Validate purchase_consistency is NOT NULL for customers with >= 3 orders."""
        for row in customer_rows:
            total_orders = int(row[1])
            consistency = row[16]
            if total_orders >= 3:
                assert consistency is not None, \
                    f"Customer {row[0]}: with {total_orders} orders should have non-NULL consistency"

    def test_value_score_range(self, customer_rows):
        """Validate customer_value_score is between 0 and 100."""
        for row in customer_rows:
            score = int(row[17])
            assert 0 <= score <= 100, \
                f"Customer {row[0]}: value_score must be 0-100, got {score}"

    def test_value_score_is_integer(self, customer_rows):
        """Validate customer_value_score is an integer."""
        for row in customer_rows:
            score = row[17]
            assert isinstance(score, int) or (isinstance(score, (float,)) and score == int(score)) or int(score) == score, \
                f"Customer {row[0]}: value_score must be integer, got {type(score)}"

    def test_segment_valid_values(self, customer_rows):
        """Validate customer_segment is one of the valid values."""
        for row in customer_rows:
            segment = row[18]
            assert segment in VALID_SEGMENTS, \
                f"Customer {row[0]}: invalid segment '{segment}'. Must be one of {VALID_SEGMENTS}"

    def test_segment_matches_score(self, customer_rows):
        """Validate customer_segment matches the customer_value_score."""
        for row in customer_rows:
            score = int(row[17])
            segment = row[18]

            if score >= 80:
                expected = 'Champion'
            elif score >= 60:
                expected = 'Loyal'
            elif score >= 40:
                expected = 'Potential'
            elif score >= 20:
                expected = 'At Risk'
            else:
                expected = 'Hibernating'

            assert segment == expected, \
                f"Customer {row[0]}: score={score} should be '{expected}', got '{segment}'"

    def test_order_acceleration_valid_values(self, customer_rows):
        """Validate order_acceleration is one of the valid values or NULL."""
        for row in customer_rows:
            accel = row[19]
            if accel is not None:
                assert accel in VALID_ACCELERATION, \
                    f"Customer {row[0]}: invalid order_acceleration '{accel}'. Must be one of {VALID_ACCELERATION} or NULL"

    def test_order_acceleration_null_for_few_orders(self, customer_rows):
        """Validate order_acceleration is NULL for customers with < 4 orders."""
        for row in customer_rows:
            total_orders = int(row[1])
            accel = row[19]
            if total_orders < 4:
                assert accel is None, \
                    f"Customer {row[0]}: with {total_orders} orders should have NULL order_acceleration, got '{accel}'"

    def test_monthly_order_rate_positive(self, customer_rows):
        """Validate monthly_order_rate is positive."""
        for row in customer_rows:
            rate = float(row[20])
            assert rate > 0, \
                f"Customer {row[0]}: monthly_order_rate must be positive, got {rate}"

    def test_spending_trend_valid_values(self, customer_rows):
        """Validate spending_trend is one of the valid values or NULL."""
        for row in customer_rows:
            trend = row[21]
            if trend is not None:
                assert trend in VALID_SPENDING_TREND, \
                    f"Customer {row[0]}: invalid spending_trend '{trend}'. Must be one of {VALID_SPENDING_TREND} or NULL"

    def test_spending_trend_null_for_single_order(self, customer_rows):
        """Validate spending_trend is NULL for single-order customers."""
        for row in customer_rows:
            total_orders = int(row[1])
            trend = row[21]
            if total_orders == 1:
                assert trend is None, \
                    f"Customer {row[0]}: single-order should have NULL spending_trend, got '{trend}'"

    def test_loyalty_index_range(self, customer_rows):
        """Validate loyalty_index is between 0 and 100."""
        for row in customer_rows:
            index = int(row[22])
            assert 0 <= index <= 100, \
                f"Customer {row[0]}: loyalty_index must be 0-100, got {index}"

    def test_loyalty_index_is_integer(self, customer_rows):
        """Validate loyalty_index is an integer."""
        for row in customer_rows:
            index = row[22]
            assert isinstance(index, int) or (isinstance(index, (float,)) and index == int(index)) or int(index) == index, \
                f"Customer {row[0]}: loyalty_index must be integer, got {type(index)}"

    def test_engagement_momentum_valid_values(self, customer_rows):
        """Validate engagement_momentum is one of the valid values."""
        for row in customer_rows:
            momentum = row[23]
            assert momentum in VALID_MOMENTUM, \
                f"Customer {row[0]}: invalid engagement_momentum '{momentum}'. Must be one of {VALID_MOMENTUM}"

    def test_engagement_momentum_inactive_for_high_days_since(self, customer_rows):
        """Validate Inactive momentum for customers with days_since >= 90."""
        for row in customer_rows:
            days_since = int(row[13])
            momentum = row[23]
            if days_since >= 90:
                assert momentum == 'Inactive', \
                    f"Customer {row[0]}: days_since={days_since} >= 90 should have Inactive momentum, got '{momentum}'"

    def test_lifecycle_stage_valid_values(self, customer_rows):
        """Validate lifecycle_stage is one of the valid values."""
        for row in customer_rows:
            stage = row[24]
            assert stage in VALID_LIFECYCLE, \
                f"Customer {row[0]}: invalid lifecycle_stage '{stage}'. Must be one of {VALID_LIFECYCLE}"

    def test_lifecycle_churned_for_high_days_since(self, customer_rows):
        """Validate Churned lifecycle for customers with days_since >= 120."""
        for row in customer_rows:
            days_since = int(row[13])
            stage = row[24]
            if days_since >= 120:
                assert stage == 'Churned', \
                    f"Customer {row[0]}: days_since={days_since} >= 120 should be Churned, got '{stage}'"


# ============ PHASE 4: SPOT CHECKS ============

class TestPhase4SpotChecks:
    """Phase 4: Spot-check specific customers."""

    def test_total_customer_count(self, customer_rows):
        """Validate total number of customers."""
        print("\n" + "="*50)
        print("PHASE 4: Spot Check Validation")
        print("="*50)
        actual_count = len(customer_rows)
        assert actual_count == EXPECTED_TOTAL_CUSTOMERS, \
            f"Expected {EXPECTED_TOTAL_CUSTOMERS} customers, got {actual_count}"

    def test_frequency_distribution(self, customer_rows):
        """Validate frequency distribution matches expected."""
        from collections import Counter
        actual_counts = Counter(row[11] for row in customer_rows)
        for freq, expected_count in EXPECTED_FREQUENCY_COUNTS.items():
            actual = actual_counts.get(freq, 0)
            assert actual == expected_count, \
                f"Frequency '{freq}': expected {expected_count}, got {actual}"

    def test_tier_distribution(self, customer_rows):
        """Validate customer tier distribution matches expected."""
        from collections import Counter
        actual_counts = Counter(row[14] for row in customer_rows)
        for tier, expected_count in EXPECTED_TIER_COUNTS.items():
            actual = actual_counts.get(tier, 0)
            assert actual == expected_count, \
                f"Tier '{tier}': expected {expected_count}, got {actual}"

    def test_churn_risk_distribution(self, customer_rows):
        """Validate churn risk distribution matches expected."""
        from collections import Counter
        actual_counts = Counter(row[15] for row in customer_rows)
        for risk, expected_count in EXPECTED_CHURN_RISK_COUNTS.items():
            actual = actual_counts.get(risk, 0)
            assert actual == expected_count, \
                f"Churn risk '{risk}': expected {expected_count}, got {actual}"

    def test_consistency_distribution(self, customer_rows):
        """Validate purchase consistency distribution matches expected."""
        from collections import Counter
        actual_counts = Counter(row[16] for row in customer_rows)
        for consistency, expected_count in EXPECTED_CONSISTENCY_COUNTS.items():
            actual = actual_counts.get(consistency, 0)
            assert actual == expected_count, \
                f"Consistency '{consistency}': expected {expected_count}, got {actual}"

    def test_segment_distribution(self, customer_rows):
        """Validate customer segment distribution matches expected."""
        from collections import Counter
        actual_counts = Counter(row[18] for row in customer_rows)
        for segment, expected_count in EXPECTED_SEGMENT_COUNTS.items():
            actual = actual_counts.get(segment, 0)
            assert actual == expected_count, \
                f"Segment '{segment}': expected {expected_count}, got {actual}"

    def test_spot_check_customers(self, customer_rows):
        """Spot-check specific customers with known values."""
        rows_by_id = {row[0]: row for row in customer_rows}

        for cust_id, exp_orders, exp_revenue, exp_freq, exp_repeat, exp_tier, exp_churn, exp_consistency, exp_score, exp_segment, exp_accel, exp_rate, exp_trend, exp_loyalty, exp_momentum, exp_lifecycle in SPOT_CHECK_CUSTOMERS:
            row = rows_by_id.get(cust_id)
            assert row is not None, f"Customer {cust_id} not found"

            assert int(row[1]) == exp_orders, \
                f"Customer {cust_id}: total_orders expected {exp_orders}, got {row[1]}"
            assert abs(float(row[5]) - exp_revenue) < 0.1, \
                f"Customer {cust_id}: total_revenue expected {exp_revenue}, got {row[5]}"
            assert row[11] == exp_freq, \
                f"Customer {cust_id}: ordering_frequency expected '{exp_freq}', got '{row[11]}'"
            assert row[12] == exp_repeat, \
                f"Customer {cust_id}: is_repeat_customer expected '{exp_repeat}', got '{row[12]}'"
            assert row[14] == exp_tier, \
                f"Customer {cust_id}: customer_tier expected '{exp_tier}', got '{row[14]}'"
            assert row[15] == exp_churn, \
                f"Customer {cust_id}: churn_risk expected '{exp_churn}', got '{row[15]}'"
            assert row[16] == exp_consistency, \
                f"Customer {cust_id}: purchase_consistency expected '{exp_consistency}', got '{row[16]}'"
            assert int(row[17]) == exp_score, \
                f"Customer {cust_id}: customer_value_score expected {exp_score}, got {row[17]}"
            assert row[18] == exp_segment, \
                f"Customer {cust_id}: customer_segment expected '{exp_segment}', got '{row[18]}'"
            assert row[19] == exp_accel, \
                f"Customer {cust_id}: order_acceleration expected '{exp_accel}', got '{row[19]}'"
            assert abs(float(row[20]) - exp_rate) < 0.5, \
                f"Customer {cust_id}: monthly_order_rate expected ~{exp_rate}, got {row[20]}"
            assert row[21] == exp_trend, \
                f"Customer {cust_id}: spending_trend expected '{exp_trend}', got '{row[21]}'"
            assert abs(int(row[22]) - exp_loyalty) <= 5, \
                f"Customer {cust_id}: loyalty_index expected ~{exp_loyalty}, got {row[22]}"
            assert row[23] == exp_momentum, \
                f"Customer {cust_id}: engagement_momentum expected '{exp_momentum}', got '{row[23]}'"
            assert row[24] == exp_lifecycle, \
                f"Customer {cust_id}: lifecycle_stage expected '{exp_lifecycle}', got '{row[24]}'"

    def test_top_customer_detailed(self, customer_rows):
        """Detailed validation of top customer."""
        rows_by_id = {row[0]: row for row in customer_rows}
        cust_id = TOP_CUSTOMER['customer_id']
        row = rows_by_id.get(cust_id)
        assert row is not None, f"Top customer {cust_id} not found"

        # Verify this is actually the top customer
        assert row == customer_rows[0], \
            f"Customer {cust_id} should be first (highest revenue)"

        # Check all detailed values
        assert int(row[1]) == TOP_CUSTOMER['total_orders'], \
            f"total_orders: expected {TOP_CUSTOMER['total_orders']}, got {row[1]}"
        assert str(row[2]) == TOP_CUSTOMER['first_order_date'] or str(row[2])[:10] == TOP_CUSTOMER['first_order_date'], \
            f"first_order_date: expected {TOP_CUSTOMER['first_order_date']}, got {row[2]}"
        assert str(row[3]) == TOP_CUSTOMER['last_order_date'] or str(row[3])[:10] == TOP_CUSTOMER['last_order_date'], \
            f"last_order_date: expected {TOP_CUSTOMER['last_order_date']}, got {row[3]}"
        assert int(row[4]) == TOP_CUSTOMER['customer_lifespan_days'], \
            f"customer_lifespan_days: expected {TOP_CUSTOMER['customer_lifespan_days']}, got {row[4]}"
        assert abs(float(row[5]) - TOP_CUSTOMER['total_revenue']) < 0.1, \
            f"total_revenue: expected {TOP_CUSTOMER['total_revenue']}, got {row[5]}"
        assert abs(float(row[7]) - TOP_CUSTOMER['avg_days_between_orders']) < 0.1, \
            f"avg_days_between_orders: expected {TOP_CUSTOMER['avg_days_between_orders']}, got {row[7]}"
        assert int(row[8]) == TOP_CUSTOMER['min_days_between_orders'], \
            f"min_days_between_orders: expected {TOP_CUSTOMER['min_days_between_orders']}, got {row[8]}"
        assert int(row[9]) == TOP_CUSTOMER['max_days_between_orders'], \
            f"max_days_between_orders: expected {TOP_CUSTOMER['max_days_between_orders']}, got {row[9]}"
        assert row[11] == TOP_CUSTOMER['ordering_frequency'], \
            f"ordering_frequency: expected {TOP_CUSTOMER['ordering_frequency']}, got {row[11]}"
        assert row[12] == TOP_CUSTOMER['is_repeat_customer'], \
            f"is_repeat_customer: expected {TOP_CUSTOMER['is_repeat_customer']}, got {row[12]}"
        assert int(row[13]) == TOP_CUSTOMER['days_since_last_order'], \
            f"days_since_last_order: expected {TOP_CUSTOMER['days_since_last_order']}, got {row[13]}"
        assert row[14] == TOP_CUSTOMER['customer_tier'], \
            f"customer_tier: expected {TOP_CUSTOMER['customer_tier']}, got {row[14]}"
        assert row[15] == TOP_CUSTOMER['churn_risk'], \
            f"churn_risk: expected {TOP_CUSTOMER['churn_risk']}, got {row[15]}"
        assert row[16] == TOP_CUSTOMER['purchase_consistency'], \
            f"purchase_consistency: expected {TOP_CUSTOMER['purchase_consistency']}, got {row[16]}"
        assert int(row[17]) == TOP_CUSTOMER['customer_value_score'], \
            f"customer_value_score: expected {TOP_CUSTOMER['customer_value_score']}, got {row[17]}"
        assert row[18] == TOP_CUSTOMER['customer_segment'], \
            f"customer_segment: expected {TOP_CUSTOMER['customer_segment']}, got {row[18]}"
        assert row[19] == TOP_CUSTOMER['order_acceleration'], \
            f"order_acceleration: expected {TOP_CUSTOMER['order_acceleration']}, got {row[19]}"
        assert row[21] == TOP_CUSTOMER['spending_trend'], \
            f"spending_trend: expected {TOP_CUSTOMER['spending_trend']}, got {row[21]}"
        assert row[23] == TOP_CUSTOMER['engagement_momentum'], \
            f"engagement_momentum: expected {TOP_CUSTOMER['engagement_momentum']}, got {row[23]}"
        assert row[24] == TOP_CUSTOMER['lifecycle_stage'], \
            f"lifecycle_stage: expected {TOP_CUSTOMER['lifecycle_stage']}, got {row[24]}"

    def test_has_one_time_customers(self, customer_rows):
        """Validate we have expected number of one-time customers."""
        one_time_count = sum(1 for row in customer_rows if int(row[1]) == 1)
        assert one_time_count == EXPECTED_FREQUENCY_COUNTS['One-time'], \
            f"Expected {EXPECTED_FREQUENCY_COUNTS['One-time']} one-time customers, got {one_time_count}"

    def test_has_repeat_customers(self, customer_rows):
        """Validate we have expected number of repeat customers."""
        repeat_count = sum(1 for row in customer_rows if int(row[1]) > 1)
        expected_repeat = EXPECTED_TOTAL_CUSTOMERS - EXPECTED_FREQUENCY_COUNTS['One-time']
        assert repeat_count == expected_repeat, \
            f"Expected {expected_repeat} repeat customers, got {repeat_count}"

    def test_customer_lifespan_matches_date_diff(self, customer_rows):
        """Validate customer_lifespan_days matches date difference."""
        for row in customer_rows:
            first = row[2]
            last = row[3]
            # Handle Snowflake returning datetime
            if hasattr(first, 'date'):
                first = first.date()
            if hasattr(last, 'date'):
                last = last.date()
            expected_days = (last - first).days
            actual_days = int(row[4])
            assert actual_days == expected_days, \
                f"Customer {row[0]}: lifespan expected {expected_days}, got {actual_days}"


# ============ PHASE 5: IDEMPOTENCY ============

class TestPhase5Idempotency:
    """Phase 5: Test idempotency."""

    def test_idempotency(self, customer_rows):
        """Test that re-running dbt produces same results."""
        print("\n" + "="*50)
        print("PHASE 5: Idempotency Test")
        print("="*50)

        rows_before = list(customer_rows)
        run_dbt_pipeline()
        rows_after = query_customer_intervals()

        assert len(rows_before) == len(rows_after), \
            f"Row count changed: {len(rows_before)} -> {len(rows_after)}"

        for before, after in zip(rows_before, rows_after):
            # Compare customer_id
            assert before[0] == after[0], f"Customer ID mismatch"

            # Compare each field
            for i in range(len(before)):
                if before[i] is None and after[i] is None:
                    continue
                if before[i] is None or after[i] is None:
                    assert False, f"NULL mismatch at index {i} for customer {before[0]}"
                if isinstance(before[i], (int, float)):
                    assert abs(float(before[i]) - float(after[i])) < 0.01, \
                        f"Value changed at index {i} for customer {before[0]}: {before[i]} -> {after[i]}"
                else:
                    assert str(before[i]) == str(after[i]), \
                        f"Value changed at index {i} for customer {before[0]}: {before[i]} -> {after[i]}"

        print(f"Idempotency verified: {len(rows_after)} customers unchanged")
