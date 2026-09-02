"""
Test verifier for dbt-fix-daily-revenue task.
Tests daily order summary model with date spine and cumulative revenue.
"""
import pytest
import subprocess
import os
from datetime import datetime, timedelta


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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def db_conn():
    """Create a database connection based on DB_TYPE"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ============ TESTS ============


def test_no_missing_dates(db_conn):
    """Test that all dates in the range are present (no gaps)"""
    conn, db_type = db_conn

    date_range = execute_query(conn, db_type, """
        SELECT MIN(order_date) as min_date, MAX(order_date) as max_date
        FROM rpt_order_daily_summary
    """)

    min_date, max_date = date_range[0]

    days_in_report = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT order_date)
        FROM rpt_order_daily_summary
    """)

    # Handle date types - Snowflake may return datetime objects
    if hasattr(min_date, 'date'):
        min_date = min_date.date()
    if hasattr(max_date, 'date'):
        max_date = max_date.date()

    expected_days = (max_date - min_date).days + 1

    assert int(days_in_report) == expected_days, \
        f"Missing dates: expected {expected_days} days, got {days_in_report}"


def test_zero_revenue_dates_exist(db_conn):
    """Test that dates with zero revenue are included (not missing)"""
    conn, db_type = db_conn

    zero_rev_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM rpt_order_daily_summary
        WHERE total_revenue = 0
    """)

    assert int(zero_rev_count) > 0, \
        f"No zero-revenue dates found - dates without orders are missing from report"


def test_cumulative_revenue_matches_total(db_conn):
    """Test that final cumulative revenue equals total revenue"""
    conn, db_type = db_conn

    final_cumulative = execute_scalar(conn, db_type, """
        SELECT cumulative_revenue
        FROM rpt_order_daily_summary
        ORDER BY order_date DESC
        LIMIT 1
    """)

    total_revenue = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(grand_total), 0)
        FROM stg_orders__orders
    """)

    tolerance = float(total_revenue) * 0.0001
    assert abs(float(final_cumulative) - float(total_revenue)) <= tolerance, \
        f"Final cumulative revenue mismatch: cumulative={final_cumulative}, total={total_revenue}"


def test_cumulative_revenue_monotonic_increasing(db_conn):
    """Test that cumulative revenue never decreases"""
    conn, db_type = db_conn

    decreases = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM (
            SELECT
                order_date,
                cumulative_revenue,
                LAG(cumulative_revenue) OVER (ORDER BY order_date) as prev_cumulative
            FROM rpt_order_daily_summary
        ) sub
        WHERE prev_cumulative IS NOT NULL
          AND cumulative_revenue < prev_cumulative
    """)

    assert int(decreases) == 0, f"Found {decreases} instances where cumulative revenue decreased"


def test_cumulative_revenue_accuracy_sample_dates(db_conn):
    """Test that cumulative revenue is correct for sample dates"""
    conn, db_type = db_conn

    sample_dates = execute_query(conn, db_type, """
        SELECT order_date, cumulative_revenue
        FROM rpt_order_daily_summary
        WHERE total_revenue > 0
        ORDER BY order_date
        LIMIT 5
    """)

    errors = []
    for order_date, reported_cumulative in sample_dates:
        if db_type == 'snowflake':
            # Snowflake uses %s placeholder; also cast ordered_at to timestamp
            actual_cumulative = execute_scalar(conn, db_type, """
                SELECT COALESCE(SUM(grand_total), 0)
                FROM stg_orders__orders
                WHERE date_trunc('day', CAST(ordered_at AS TIMESTAMP)) <= %s
            """, [order_date])
        else:
            actual_cumulative = execute_scalar(conn, db_type, """
                SELECT COALESCE(SUM(grand_total), 0)
                FROM stg_orders__orders
                WHERE date_trunc('day', ordered_at) <= ?
            """, [order_date])

        tolerance = max(float(actual_cumulative) * 0.0001, 0.01)
        if abs(float(reported_cumulative) - float(actual_cumulative)) > tolerance:
            errors.append(f"{order_date}: report={reported_cumulative}, actual={actual_cumulative}")

    assert len(errors) == 0, f"Cumulative revenue errors: {'; '.join(errors)}"


def test_date_sequence_continuous(db_conn):
    """Test that dates form a continuous sequence with no gaps"""
    conn, db_type = db_conn

    gaps = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM (
            SELECT
                order_date,
                LAG(order_date) OVER (ORDER BY order_date) as prev_date,
                DATEDIFF('day', LAG(order_date) OVER (ORDER BY order_date), order_date) as day_diff
            FROM rpt_order_daily_summary
        ) sub
        WHERE prev_date IS NOT NULL
          AND day_diff != 1
    """)

    assert int(gaps) == 0, f"Found {gaps} gaps in date sequence"


def test_no_null_revenue_values(db_conn):
    """Test that revenue columns don't have NULLs (should be 0 instead)"""
    conn, db_type = db_conn

    null_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM rpt_order_daily_summary
        WHERE total_revenue IS NULL
           OR cumulative_revenue IS NULL
    """)

    assert int(null_count) == 0, f"Found {null_count} rows with NULL revenue values"


def test_zero_revenue_days_have_zero_orders(db_conn):
    """Test that days with 0 revenue also have 0 orders"""
    conn, db_type = db_conn

    mismatch_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM rpt_order_daily_summary
        WHERE total_revenue = 0
          AND total_orders != 0
    """)

    assert int(mismatch_count) == 0, \
        f"Found {mismatch_count} days with 0 revenue but non-zero orders"


def test_revenue_sum_matches_orders(db_conn):
    """Test that sum of daily revenue matches order totals"""
    conn, db_type = db_conn

    report_sum = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(total_revenue), 0)
        FROM rpt_order_daily_summary
    """)

    orders_sum = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(grand_total), 0)
        FROM stg_orders__orders
    """)

    tolerance = float(orders_sum) * 0.0001
    assert abs(float(report_sum) - float(orders_sum)) <= tolerance, \
        f"Daily revenue sum mismatch: report={report_sum}, orders={orders_sum}"


def test_cumulative_starts_with_first_day_revenue(db_conn):
    """Test that first day's cumulative equals that day's revenue"""
    conn, db_type = db_conn

    first_day = execute_query(conn, db_type, """
        SELECT total_revenue, cumulative_revenue
        FROM rpt_order_daily_summary
        ORDER BY order_date
        LIMIT 1
    """)

    total_rev, cumulative_rev = first_day[0]

    tolerance = max(float(total_rev) * 0.0001, 0.01)
    assert abs(float(total_rev) - float(cumulative_rev)) <= tolerance, \
        f"First day cumulative mismatch: daily={total_rev}, cumulative={cumulative_rev}"


def test_model_structure_preserved(db_conn):
    """Test that all required columns exist"""
    conn, db_type = db_conn

    required_columns = [
        'order_date', 'total_orders', 'unique_customers', 'total_revenue',
        'subtotal_revenue', 'total_discounts', 'total_shipping', 'total_tax',
        'avg_order_value', 'cumulative_revenue'
    ]

    result = execute_query(conn, db_type, """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_name) = 'rpt_order_daily_summary'
    """)

    existing_columns = [row[0].lower() for row in result]

    for col in required_columns:
        assert col.lower() in existing_columns, f"Required column '{col}' is missing"


def test_no_duplicate_dates(db_conn):
    """Test that each date appears exactly once"""
    conn, db_type = db_conn

    duplicates = execute_scalar(conn, db_type, """
        SELECT COUNT(*) - COUNT(DISTINCT order_date)
        FROM rpt_order_daily_summary
    """)

    assert int(duplicates) == 0, f"Found {duplicates} duplicate dates"


def test_cumulative_never_zero_after_first_revenue(db_conn):
    """Test that cumulative stays positive once revenue starts"""
    conn, db_type = db_conn

    # Get first date with revenue
    first_revenue_date = execute_scalar(conn, db_type, """
        SELECT MIN(order_date)
        FROM rpt_order_daily_summary
        WHERE total_revenue > 0
    """)

    # Check no zero cumulative after that date
    if db_type == 'snowflake':
        zero_cumulative_after = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM rpt_order_daily_summary
            WHERE order_date >= %s
              AND cumulative_revenue = 0
        """, [first_revenue_date])
    else:
        zero_cumulative_after = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM rpt_order_daily_summary
            WHERE order_date >= ?
              AND cumulative_revenue = 0
        """, [first_revenue_date])

    assert int(zero_cumulative_after) == 0, \
        f"Found {zero_cumulative_after} dates with zero cumulative after first revenue"
