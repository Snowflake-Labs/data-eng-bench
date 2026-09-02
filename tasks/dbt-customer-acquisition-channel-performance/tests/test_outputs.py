"""
Verifier for Customer Acquisition Channel Performance task.
Supports both DuckDB and Snowflake backends.
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


def _get_schema():
    """Return the schema name where the output model is materialized, based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'analytics'


SCHEMA = _get_schema()


# ============ HELPERS ============


def run_cmd(cmd, cwd="/app/dbt_project"):
    """Execute a shell command and return the result with captured output."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:800]}")
    return result


def require(cond, msg):
    """Assert a condition and raise an AssertionError with a custom message if it fails."""
    if not cond:
        raise AssertionError(msg)


def run_dbt_pipeline():
    """Build the dbt pipeline by running dependencies, staging models, and the target model."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        # Snowflake: staging models are pre-built, just run the mart model
        # Drop existing target table if present
        conn_cleanup, _ = get_db_connection()
        try:
            cursor = conn_cleanup.cursor()
            cursor.execute(f"DROP TABLE IF EXISTS {SCHEMA}.rpt_customer_acquisition_channel_performance_fixed")
        except Exception:
            pass
        finally:
            conn_cleanup.close()

        res = run_cmd("dbt run --profiles-dir . --select rpt_customer_acquisition_channel_performance_fixed --full-refresh")
        if res.returncode != 0:
            err = res.stderr or res.stdout
            require(False, f"dbt run failed: {err[:1500]}")
    else:
        # DuckDB: build staging first, then mart model
        run_cmd("cd /app/dbt_models_duckdb && dbt deps", cwd="/app")
        res = run_cmd(
            "cd /app/dbt_models_duckdb && "
            "dbt run --select int_sales__orders_enriched stg_orders__orders",
            cwd="/app",
        )
        require(res.returncode == 0, "Failed to build required staging models")

        # Drop existing target table if present (DuckDB only)
        import duckdb
        drop_conn = duckdb.connect("/app/database/retail.duckdb")
        for name in [
            "analytics.rpt_customer_acquisition_channel_performance_fixed",
            "ANALYTICS.rpt_customer_acquisition_channel_performance_fixed",
            "rpt_customer_acquisition_channel_performance_fixed",
        ]:
            try:
                drop_conn.execute(f"DROP TABLE IF EXISTS {name}")
            except Exception:
                pass
        drop_conn.close()

        # Run agent model
        res2 = run_cmd("dbt run --select rpt_customer_acquisition_channel_performance_fixed --full-refresh")
        if res2.returncode != 0:
            err = res2.stderr or res2.stdout
            require(False, f"dbt run failed: {err[:1500]}")


# ============ FIXTURE ============


@pytest.fixture(scope="module")
def conn():
    """Pytest fixture providing a database connection (DuckDB or Snowflake)."""
    require(os.path.exists("/app/dbt_project"), "dbt_project directory missing")
    require(
        os.path.exists("/app/dbt_project/models/marts/marketing/rpt_customer_acquisition_channel_performance_fixed.sql"),
        "Model file missing",
    )
    run_dbt_pipeline()
    c, db_type = get_db_connection()
    yield c, db_type
    c.close()


# ============ TESTS ============


def test_schema(conn):
    """Test that output table has correct schema."""
    c, db_type = conn

    if db_type == 'snowflake':
        cols = execute_query(c, db_type, f"""
            SELECT LOWER(column_name), data_type
            FROM information_schema.columns
            WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
            AND LOWER(table_name) = 'rpt_customer_acquisition_channel_performance_fixed'
        """)
    else:
        cols = execute_query(c, db_type, f"""
            SELECT name, type
            FROM pragma_table_info('{SCHEMA}.rpt_customer_acquisition_channel_performance_fixed')
            ORDER BY cid
        """)

    expected_cols = {
        "acquisition_channel",
        "customer_count",
        "total_orders",
        "total_revenue",
        "average_order_value",
        "customer_lifetime_value",
        "average_orders_per_customer",
        "repeat_purchase_rate",
        "channel_tier",
    }
    actual_cols = {name.lower() for name, _ in cols}
    missing = expected_cols - actual_cols
    require(not missing, f"Missing columns: {missing}")


def test_data_quality(conn):
    """Test non-negative values and valid ranges."""
    c, db_type = conn

    # Use SUM(CASE WHEN ...) instead of COUNT(*) FILTER (WHERE ...) for cross-DB compat
    issues = execute_query(c, db_type, f"""
        SELECT
            SUM(CASE WHEN customer_count < 0 THEN 1 ELSE 0 END) AS negative_customers,
            SUM(CASE WHEN total_orders < 0 THEN 1 ELSE 0 END) AS negative_orders,
            SUM(CASE WHEN total_revenue < 0 THEN 1 ELSE 0 END) AS negative_revenue,
            SUM(CASE WHEN average_order_value < 0 THEN 1 ELSE 0 END) AS negative_aov,
            SUM(CASE WHEN customer_lifetime_value < 0 THEN 1 ELSE 0 END) AS negative_cltv,
            SUM(CASE WHEN average_orders_per_customer < 0 THEN 1 ELSE 0 END) AS negative_avg_orders,
            SUM(CASE WHEN repeat_purchase_rate < 0 OR repeat_purchase_rate > 100 THEN 1 ELSE 0 END) AS invalid_repeat_rate
        FROM {SCHEMA}.rpt_customer_acquisition_channel_performance_fixed
    """)
    row = issues[0]
    (
        neg_cust,
        neg_ord,
        neg_rev,
        neg_aov,
        neg_cltv,
        neg_avg_ord,
        inv_repeat,
    ) = [int(v) for v in row]
    require(neg_cust == 0, f"Found {neg_cust} rows with negative customer_count")
    require(neg_ord == 0, f"Found {neg_ord} rows with negative total_orders")
    require(neg_rev == 0, f"Found {neg_rev} rows with negative total_revenue")
    require(neg_aov == 0, f"Found {neg_aov} rows with negative average_order_value")
    require(neg_cltv == 0, f"Found {neg_cltv} rows with negative customer_lifetime_value")
    require(neg_avg_ord == 0, f"Found {neg_avg_ord} rows with negative average_orders_per_customer")
    require(inv_repeat == 0, f"Found {inv_repeat} rows with invalid repeat_purchase_rate")


def test_metric_consistency(conn):
    """Test that calculated metrics are consistent."""
    c, db_type = conn

    issues = execute_scalar(c, db_type, f"""
        SELECT COUNT(*) AS inconsistency_count
        FROM {SCHEMA}.rpt_customer_acquisition_channel_performance_fixed
        WHERE (
            ABS(average_order_value - (total_revenue / NULLIF(total_orders, 0))) > 0.01
            OR ABS(customer_lifetime_value - (total_revenue / NULLIF(customer_count, 0))) > 0.01
            OR ABS(average_orders_per_customer - (CAST(total_orders AS DECIMAL(18,2)) / NULLIF(customer_count, 0))) > 0.01
        )
    """)
    require(int(issues) == 0, f"Found {issues} rows with inconsistent calculated metrics")


def test_channel_tier_logic(conn):
    """Test that channel_tier matches the defined logic."""
    c, db_type = conn

    issues = execute_scalar(c, db_type, f"""
        SELECT COUNT(*) AS tier_mismatch_count
        FROM {SCHEMA}.rpt_customer_acquisition_channel_performance_fixed
        WHERE (
            (customer_lifetime_value > 500 AND repeat_purchase_rate > 30 AND channel_tier != 'HIGH_VALUE')
            OR (customer_count > 100 AND customer_lifetime_value > 200 AND channel_tier != 'VOLUME' AND channel_tier != 'HIGH_VALUE')
            OR ((customer_lifetime_value < 100 OR repeat_purchase_rate < 10) AND channel_tier NOT IN ('LOW_QUALITY', 'STANDARD'))
        )
    """)
    # Allow some flexibility since tiers can overlap
    require(int(issues) == 0, f"Found {issues} rows with potentially incorrect channel_tier classification")


def test_reconciliation(conn):
    """Test that channel totals reconcile with source data."""
    c, db_type = conn

    # Get total customers and revenue from output
    out_totals = execute_query(c, db_type, f"""
        SELECT
            SUM(customer_count) AS total_customers,
            SUM(total_orders) AS total_orders,
            SUM(total_revenue) AS total_revenue
        FROM {SCHEMA}.rpt_customer_acquisition_channel_performance_fixed
    """)
    if not out_totals or out_totals[0][0] is None:
        return  # No data to reconcile

    out_customers, out_orders, out_revenue = out_totals[0]

    # Recompute from source
    src = execute_query(c, db_type, """
        SELECT
            COUNT(DISTINCT o.customer_id) AS customers,
            COUNT(DISTINCT o.order_id) AS orders,
            SUM(o.grand_total) AS revenue
        FROM main.int_sales__orders_enriched o
        JOIN main.stg_orders__orders so ON o.order_id = so.order_id
        WHERE o.status != 'CANCELLED'
          AND o.customer_id IS NOT NULL
          AND o.ordered_at IS NOT NULL
    """)
    if not src:
        return

    src_customers, src_orders, src_revenue = src[0]

    # Allow some variance since we're only counting customers with attribution
    customers_diff = abs(float(out_customers) - float(src_customers))
    orders_diff = abs(float(out_orders) - float(src_orders))
    revenue_diff = abs(float(out_revenue) - float(src_revenue))

    # Allow up to 20% variance for customers (some may not have attribution)
    require(
        customers_diff <= float(src_customers) * 0.2 or customers_diff <= 10,
        f"Customer count mismatch: out={out_customers}, src={src_customers}, diff={customers_diff}"
    )
    require(
        orders_diff <= float(src_orders) * 0.12 or orders_diff <= 50,
        f"Order count mismatch: out={out_orders}, src={src_orders}, diff={orders_diff}"
    )
    require(
        revenue_diff <= float(src_revenue) * 0.12 or revenue_diff <= 1000,
        f"Revenue mismatch: out={out_revenue}, src={src_revenue}, diff={revenue_diff}"
    )
