"""
Verifier for Customer Churn Early Warning task.
"""
import os
import subprocess
import pytest

# ============ CONFIGURATION ============

DB_PATH = "/app/database/retail.duckdb"
PROJECT_DIR = "/app/dbt_project"
SCHEMA = "analytics"

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
            schema=SCHEMA,
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', DB_PATH)
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def get_db_connection_rw():
    """Create a read-write database connection (DuckDB only, for cleanup)."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        # Snowflake connections are always read-write
        return get_db_connection()
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', DB_PATH)
        conn = duckdb.connect(db_path, read_only=False)
        return conn, 'duckdb'


def execute_query(conn, db_type, query, params=None):
    """Execute a query and return results, handling differences between DuckDB and Snowflake."""
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
    """Execute a query and return a single scalar value."""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ HELPERS ============

def run_cmd(cmd, cwd=PROJECT_DIR):
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:2000]}")
    return result


def require(cond, msg):
    if not cond:
        raise AssertionError(msg)


def run_dbt_pipeline():
    """Build reference model and run the agent's model."""
    ref_dir = get_dbt_project_dir()
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    # Build reference model int_sales__orders_enriched
    run_cmd("dbt deps", cwd=ref_dir)
    if db_type == 'snowflake':
        res = run_cmd("dbt run --select int_sales__orders_enriched", cwd=ref_dir)
    else:
        res = run_cmd("dbt run --select int_sales__orders_enriched", cwd=ref_dir)
    require(res.returncode == 0, "Failed to build int_sales__orders_enriched")

    # Drop output first (DuckDB only - Snowflake uses --full-refresh)
    if db_type == 'duckdb':
        conn, ct = get_db_connection_rw()
        for name in [
            "analytics.rpt_customer_churn_early_warning_fixed",
            "ANALYTICS.rpt_customer_churn_early_warning_fixed",
            "rpt_customer_churn_early_warning_fixed",
        ]:
            try:
                conn.execute(f"DROP TABLE IF EXISTS {name}")
            except Exception:
                pass
        conn.close()

    res2 = run_cmd("dbt run --select rpt_customer_churn_early_warning_fixed --full-refresh", cwd=PROJECT_DIR)
    if res2.returncode != 0:
        err = res2.stderr or res2.stdout
        require(False, f"dbt run failed: {err[:1500]}")


@pytest.fixture(scope="module")
def conn():
    require(os.path.exists(PROJECT_DIR), "dbt_project directory missing")
    require(
        os.path.exists(os.path.join(PROJECT_DIR, "models", "marts", "customer", "rpt_customer_churn_early_warning_fixed.sql")),
        "Model missing: models/marts/customer/rpt_customer_churn_early_warning_fixed.sql",
    )
    run_dbt_pipeline()
    c, db_type = get_db_connection()
    yield c, db_type
    c.close()


def test_schema(conn):
    """Validate that all required columns exist in the churn early warning model."""
    c, db_type = conn
    if db_type == 'duckdb':
        cols = execute_query(c, db_type, """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_customer_churn_early_warning_fixed')
            ORDER BY cid
        """)
    else:
        cols = execute_query(c, db_type, f"""
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE lower(table_schema) = 'analytics'
              AND lower(table_name) = 'rpt_customer_churn_early_warning_fixed'
            ORDER BY ordinal_position
        """)
    col_names = {c_row[0].lower() for c_row in cols}
    required = {
        "customer_id",
        "week_start",
        "first_order_date",
        "last_order_date",
        "days_since_last_order",
        "order_count_90d",
        "lifetime_orders",
        "lifetime_revenue",
        "churn_risk_tier",
    }
    missing = required - col_names
    require(not missing, f"Missing required columns: {missing}")


def test_data_quality(conn):
    """Check for non-empty output with no NULL customer IDs or negative revenue/order values."""
    c, db_type = conn
    row = execute_query(c, db_type, f"""
        SELECT
          COUNT(*) AS total,
          SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END) AS null_ids,
          SUM(CASE WHEN lifetime_revenue < 0 THEN 1 ELSE 0 END) AS neg_rev,
          SUM(CASE WHEN lifetime_orders < 0 THEN 1 ELSE 0 END) AS neg_orders
        FROM {SCHEMA}.rpt_customer_churn_early_warning_fixed
    """)[0]
    total, null_ids, neg_rev, neg_orders = int(row[0]), int(row[1]), int(row[2]), int(row[3])
    require(total > 0, "No rows produced")
    require(null_ids == 0, f"Found {null_ids} NULL customer_id rows")
    require(neg_rev == 0, f"Found {neg_rev} negative lifetime_revenue rows")
    require(neg_orders == 0, f"Found {neg_orders} negative lifetime_orders rows")


def test_risk_tiers(conn):
    """Verify churn_risk_tier values are valid and consistent with days_since_last_order thresholds."""
    c, db_type = conn
    # Valid tier values
    tiers = {r[0].lower() if r[0] else r[0] for r in execute_query(c, db_type, f"""
        SELECT DISTINCT churn_risk_tier FROM {SCHEMA}.rpt_customer_churn_early_warning_fixed
    """)}
    allow = {"low", "medium", "high"}
    require(tiers.issubset(allow), f"Unexpected churn_risk_tier values: {tiers - allow}")

    # Consistency with days_since_last_order
    bad = int(execute_scalar(c, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_customer_churn_early_warning_fixed
        WHERE (lower(churn_risk_tier) = 'low'    AND days_since_last_order > 30)
           OR (lower(churn_risk_tier) = 'medium' AND (days_since_last_order < 31 OR days_since_last_order > 90))
           OR (lower(churn_risk_tier) = 'high'   AND days_since_last_order <= 90)
    """))
    require(bad == 0, f"Found {bad} rows where churn_risk_tier does not match days_since_last_order thresholds")


def test_reconciliation(conn):
    """Reconcile lifetime orders and revenue against the source int_sales__orders_enriched model."""
    c, db_type = conn
    # Source aggregates from int_sales__orders_enriched
    # Use main schema for the reference model
    src = execute_query(c, db_type, """
        WITH src AS (
          SELECT
            customer_id,
            COUNT(DISTINCT order_id) AS orders,
            ROUND(SUM(CAST(grand_total AS DECIMAL(18,2))), 2) AS revenue
          FROM main.int_sales__orders_enriched
          WHERE customer_id IS NOT NULL
            AND ordered_at IS NOT NULL
          GROUP BY customer_id
        ),
        agg AS (
          SELECT
            COUNT(*) AS customers,
            SUM(orders) AS total_orders,
            ROUND(SUM(revenue), 2) AS total_revenue
          FROM src
        )
        SELECT customers, total_orders, total_revenue FROM agg
    """)[0]
    src_customers = int(src[0])
    src_orders = int(src[1])
    src_revenue = float(src[2])

    out = execute_query(c, db_type, f"""
        SELECT
          COUNT(*) AS customers,
          SUM(lifetime_orders) AS total_orders,
          ROUND(SUM(lifetime_revenue), 2) AS total_revenue
        FROM {SCHEMA}.rpt_customer_churn_early_warning_fixed
    """)[0]
    out_customers = int(out[0])
    out_orders = int(out[1])
    out_revenue = float(out[2])

    require(abs(out_orders - src_orders) <= 1, f"Order counts mismatch src={src_orders}, out={out_orders}")
    revenue_var = abs(out_revenue - src_revenue) / max(abs(src_revenue), 1.0)
    require(revenue_var <= 0.0001, f"Revenue mismatch src={src_revenue}, out={out_revenue}, var={revenue_var:.5f}")
