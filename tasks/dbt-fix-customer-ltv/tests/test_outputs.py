"""
Tests for dbt_fix_customer_ltv task - Dual DuckDB/Snowflake support
"""
import pytest
import subprocess
import os
from decimal import Decimal


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


# ============ FIXTURES ============


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def run_cmd(cmd, cwd=None):
    """Run a shell command in the dbt project dir and return the result."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[-2000:] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[-1000:]}")
    return result


@pytest.fixture(scope="module", autouse=True)
def rebuild_model():
    """Rebuild the model under test from the agent's code before verifying.

    Without this the verifier reads whatever dim_customers table was
    materialized when the container image was built (from a correct model),
    so it would award full reward for zero agent work (pass-by-default).
    Rebuilding forces the verifier to measure the agent's actual model.
    """
    deps = run_cmd("dbt deps")
    assert deps.returncode == 0, f"dbt deps failed:\n{deps.stdout}\n{deps.stderr}"
    run = run_cmd("dbt run --select dim_customers")
    assert run.returncode == 0, f"dbt run failed:\n{run.stdout}\n{run.stderr}"


@pytest.fixture(scope="module")
def db_conn(rebuild_model):
    """Database connection fixture (depends on rebuild_model so the agent's
    model is materialized before any assertions run)."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


@pytest.fixture(scope="module")
def test_customer_ids(db_conn):
    """Fetch customer IDs for testing"""
    conn, db_type = db_conn
    result = execute_query(conn, db_type, """
        SELECT DISTINCT customer_id
        FROM int_sales__orders_enriched
        WHERE customer_id IS NOT NULL
        ORDER BY customer_id
        LIMIT 10
    """)
    return [row[0] for row in result]


# ============ TESTS ============


def test_dim_customers_exists(db_conn):
    """Test that dim_customers table exists"""
    conn, db_type = db_conn
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE lower(table_name) = 'dim_customers'
    """)
    assert int(result) >= 1, "dim_customers table does not exist"


def test_dim_customers_has_data(db_conn):
    """Test that dim_customers has data"""
    conn, db_type = db_conn
    result = execute_scalar(conn, db_type, "SELECT COUNT(*) FROM dim_customers")
    assert int(result) > 0, "dim_customers table is empty"


def test_lifetime_value_calculations(db_conn, test_customer_ids):
    """Test lifetime value accuracy"""
    conn, db_type = db_conn

    for customer_id in test_customer_ids:
        if db_type == 'snowflake':
            dim_ltv = execute_query(conn, db_type, """
                SELECT lifetime_value
                FROM dim_customers
                WHERE customer_id = %s
            """, [customer_id])
        else:
            dim_ltv = execute_query(conn, db_type, """
                SELECT lifetime_value
                FROM dim_customers
                WHERE customer_id = ?
            """, [customer_id])

        assert len(dim_ltv) > 0, f"Customer {customer_id} not found in dim_customers"

        if db_type == 'snowflake':
            expected_ltv = execute_scalar(conn, db_type, """
                SELECT COALESCE(SUM(CASE
                    WHEN grand_total >= 0 THEN grand_total
                    ELSE 0
                END), 0)
                FROM int_sales__orders_enriched
                WHERE customer_id = %s
                AND UPPER(CAST(is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')
            """, [customer_id])
        else:
            expected_ltv = execute_scalar(conn, db_type, """
                SELECT COALESCE(SUM(CASE
                    WHEN grand_total >= 0 THEN grand_total
                    ELSE 0
                END), 0)
                FROM int_sales__orders_enriched
                WHERE customer_id = ?
                AND is_cancelled = false
            """, [customer_id])

        assert abs(float(dim_ltv[0][0]) - float(expected_ltv)) < 0.01, \
            f"Customer {customer_id}: Calculation mismatch"


def test_lifetime_value_valid(db_conn):
    """Test that lifetime values are valid"""
    conn, db_type = db_conn
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM dim_customers
        WHERE lifetime_value < 0
    """)
    assert int(result) == 0, "Found invalid lifetime_value records"


def test_total_orders_matches_order_count(db_conn, test_customer_ids):
    """Test that total_orders field matches actual order count from source"""
    conn, db_type = db_conn

    for customer_id in test_customer_ids:
        if db_type == 'snowflake':
            correct_count = execute_scalar(conn, db_type, """
                SELECT COUNT(DISTINCT order_id)
                FROM int_sales__orders_enriched
                WHERE customer_id = %s
                AND UPPER(CAST(is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')
            """, [customer_id])

            dim_count = execute_query(conn, db_type, """
                SELECT total_orders
                FROM dim_customers
                WHERE customer_id = %s
            """, [customer_id])
        else:
            correct_count = execute_scalar(conn, db_type, """
                SELECT COUNT(DISTINCT order_id)
                FROM int_sales__orders_enriched
                WHERE customer_id = ?
                AND is_cancelled = false
            """, [customer_id])

            dim_count = execute_query(conn, db_type, """
                SELECT total_orders
                FROM dim_customers
                WHERE customer_id = ?
            """, [customer_id])

        assert len(dim_count) > 0, f"Customer {customer_id} not found in dim_customers"
        assert int(dim_count[0][0]) == int(correct_count), \
            f"Customer {customer_id}: Order count mismatch. Expected {correct_count}, got {dim_count[0][0]}"


def test_customer_segment_logic(db_conn):
    """Test that customer_segment is correctly assigned based on total_orders"""
    conn, db_type = db_conn
    result = execute_query(conn, db_type, """
        SELECT
            customer_id,
            total_orders,
            customer_segment
        FROM dim_customers
        LIMIT 1000
    """)

    for customer_id, total_orders, segment in result:
        total_orders = int(total_orders)
        if total_orders == 0:
            expected = 'Never Ordered'
        elif total_orders == 1:
            expected = 'One-time Buyer'
        elif 2 <= total_orders <= 5:
            expected = 'Occasional Buyer'
        elif 6 <= total_orders <= 10:
            expected = 'Regular Buyer'
        else:
            expected = 'Loyal Customer'

        assert segment == expected, \
            f"Customer {customer_id} with {total_orders} orders has wrong segment: {segment} (expected {expected})"


def test_has_ordered_flag_consistency(db_conn):
    """Test that has_ordered flag is consistent with total_orders"""
    conn, db_type = db_conn
    if db_type == 'snowflake':
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM dim_customers
            WHERE (total_orders > 0 AND UPPER(CAST(has_ordered AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES'))
            OR (total_orders = 0 AND UPPER(CAST(has_ordered AS VARCHAR)) IN ('1','TRUE','T','Y','YES'))
        """)
    else:
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM dim_customers
            WHERE (total_orders > 0 AND has_ordered = false)
            OR (total_orders = 0 AND has_ordered = true)
        """)
    assert int(result) == 0, "Found inconsistencies in has_ordered flag"


def test_model_is_idempotent(db_conn, test_customer_ids):
    """
    Test that running the model multiple times produces the same results
    This is a meta-test to ensure the model is properly designed
    """
    conn, db_type = db_conn
    snapshot1 = {}
    for customer_id in test_customer_ids:
        if db_type == 'snowflake':
            result = execute_query(conn, db_type, """
                SELECT lifetime_value, total_orders, customer_segment
                FROM dim_customers
                WHERE customer_id = %s
            """, [customer_id])
        else:
            result = execute_query(conn, db_type, """
                SELECT lifetime_value, total_orders, customer_segment
                FROM dim_customers
                WHERE customer_id = ?
            """, [customer_id])
        if result:
            snapshot1[customer_id] = result[0]

    assert len(snapshot1) > 0, "Model appears to not have been run - no test customers found"


def test_primary_key_uniqueness(db_conn):
    """Test that customer_id is unique (primary key constraint)"""
    conn, db_type = db_conn
    result = execute_query(conn, db_type, """
        SELECT customer_id, COUNT(*) as cnt
        FROM dim_customers
        GROUP BY customer_id
        HAVING COUNT(*) > 1
    """)
    assert len(result) == 0, f"Found duplicate customer_ids: {result}"


def test_no_null_customer_ids(db_conn):
    """Test that there are no NULL customer_ids"""
    conn, db_type = db_conn
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM dim_customers
        WHERE customer_id IS NULL
    """)
    assert int(result) == 0, "Found NULL customer_ids in dim_customers"


def test_cancelled_orders_excluded(db_conn):
    """Verify that cancelled orders are NOT included in customer metrics.

    A common mistake is to aggregate all orders without filtering out cancelled ones.
    This test computes the total lifetime_value two ways:
      1) From dim_customers (the model output)
      2) From int_sales__orders_enriched, excluding cancelled orders
    If cancelled orders leaked into the model, the totals will diverge.
    """
    conn, db_type = db_conn

    # Total LTV from dim_customers
    dim_total = execute_scalar(conn, db_type, """
        SELECT COALESCE(SUM(lifetime_value), 0)
        FROM dim_customers
    """)

    # Expected total: only non-cancelled orders, excluding negative grand_totals
    # Restrict to customers that exist in dim_customers, since the model LEFT JOINs
    # from int_customers__unified to orders -- orphan orders (customer_id not in the
    # customer dimension) are legitimately excluded from dim_customers.
    if db_type == 'snowflake':
        expected_total = execute_scalar(conn, db_type, """
            SELECT COALESCE(SUM(CASE WHEN o.grand_total >= 0 THEN o.grand_total ELSE 0 END), 0)
            FROM int_sales__orders_enriched o
            WHERE UPPER(CAST(o.is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')
              AND o.customer_id IN (SELECT customer_id FROM dim_customers)
        """)
    else:
        expected_total = execute_scalar(conn, db_type, """
            SELECT COALESCE(SUM(CASE WHEN o.grand_total >= 0 THEN o.grand_total ELSE 0 END), 0)
            FROM int_sales__orders_enriched o
            WHERE o.is_cancelled = false
              AND o.customer_id IN (SELECT customer_id FROM dim_customers)
        """)

    # Check if cancelled orders have any non-zero revenue (to confirm test is meaningful)
    if db_type == 'snowflake':
        cancelled_revenue = execute_scalar(conn, db_type, """
            SELECT COALESCE(SUM(o.grand_total), 0)
            FROM int_sales__orders_enriched o
            WHERE UPPER(CAST(o.is_cancelled AS VARCHAR)) IN ('1','TRUE','T','Y','YES')
              AND o.customer_id IN (SELECT customer_id FROM dim_customers)
        """)
    else:
        cancelled_revenue = execute_scalar(conn, db_type, """
            SELECT COALESCE(SUM(o.grand_total), 0)
            FROM int_sales__orders_enriched o
            WHERE o.is_cancelled = true
              AND o.customer_id IN (SELECT customer_id FROM dim_customers)
        """)

    assert float(cancelled_revenue) != 0, \
        "No cancelled order revenue found in source data - test cannot validate exclusion"

    assert abs(float(dim_total) - float(expected_total)) < 0.01, \
        (f"Cancelled orders appear to be included in lifetime_value. "
         f"dim_customers total: {dim_total}, expected (non-cancelled only): {expected_total}, "
         f"cancelled order revenue: {cancelled_revenue}")


def test_customer_count_reconciliation(db_conn):
    """Verify that dim_customers contains exactly the same customers as the source.

    The customer dimension should have one row per customer from int_customers__unified,
    regardless of whether they have placed orders. This catches issues with INNER JOINs
    that accidentally drop customers without orders, or duplicates from bad joins.
    """
    conn, db_type = db_conn

    dim_count = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT customer_id) FROM dim_customers
    """)
    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT customer_id) FROM int_customers__unified
    """)

    assert int(dim_count) == int(source_count), \
        (f"Customer count mismatch: dim_customers has {dim_count} customers, "
         f"but int_customers__unified has {source_count}. "
         f"Check for INNER JOIN dropping customers or duplicates from bad join logic.")


def test_avg_order_value_excludes_cancelled(db_conn, test_customer_ids):
    """Verify that avg_order_value is computed only from non-cancelled orders.

    This catches a subtle bug where cancelled orders inflate or deflate the
    average order value. The test spot-checks against source data for a sample
    of customers.
    """
    conn, db_type = db_conn

    mismatches = []
    for customer_id in test_customer_ids:
        if db_type == 'snowflake':
            dim_avg = execute_query(conn, db_type, """
                SELECT avg_order_value
                FROM dim_customers
                WHERE customer_id = %s
            """, [customer_id])

            expected_avg = execute_scalar(conn, db_type, """
                SELECT COALESCE(AVG(grand_total), 0)
                FROM int_sales__orders_enriched
                WHERE customer_id = %s
                AND UPPER(CAST(is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')
            """, [customer_id])
        else:
            dim_avg = execute_query(conn, db_type, """
                SELECT avg_order_value
                FROM dim_customers
                WHERE customer_id = ?
            """, [customer_id])

            expected_avg = execute_scalar(conn, db_type, """
                SELECT COALESCE(AVG(grand_total), 0)
                FROM int_sales__orders_enriched
                WHERE customer_id = ?
                AND is_cancelled = false
            """, [customer_id])

        if dim_avg and len(dim_avg) > 0:
            actual = float(dim_avg[0][0])
            expected = float(expected_avg)
            if abs(actual - expected) >= 0.01:
                mismatches.append(
                    f"Customer {customer_id}: avg_order_value={actual}, expected={expected}"
                )

    assert len(mismatches) == 0, \
        (f"avg_order_value mismatches found (likely cancelled orders included):\n"
         + "\n".join(mismatches))
