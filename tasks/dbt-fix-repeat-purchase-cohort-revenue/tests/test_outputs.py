"""
Adversarial verifier for Repeat Purchase Cohort Revenue

Goals: detect schema drift, broken cohort math, cumulative inconsistencies,
reconciliation gaps, and non-idempotent runs.
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
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def get_db_connection_writable():
    """Create a writable database connection (DuckDB only, for cleanup)"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        return get_db_connection()
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path)
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


def _get_schema():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'analytics'


SCHEMA = _get_schema()
DB_PATH = "/app/database/retail.duckdb"
PROJECT_DIR = "/app/dbt_project"
MODEL_PATH = "/app/dbt_project/models/marts/customer/rpt_repeat_purchase_cohort_revenue_fixed.sql"


# ============ HELPERS ============


def run_cmd(cmd, cwd="/app"):
    """Execute a shell command and return the result with captured output."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1200]}")
    return result


def require(cond, msg):
    """Assert a condition with a custom message."""
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
            cursor.execute(f"DROP TABLE IF EXISTS {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed")
        except Exception:
            pass
        finally:
            conn_cleanup.close()

        dbt_project_dir = "/app/dbt_models_snowflake"
        res = run_cmd(
            f"cd {dbt_project_dir} && dbt run --profiles-dir . --select rpt_repeat_purchase_cohort_revenue_fixed --full-refresh",
            cwd=dbt_project_dir,
        )
        if res.returncode != 0:
            err = res.stderr or res.stdout
            require(False, f"dbt run failed: {err[:1500]}")
    else:
        # DuckDB: build staging first, then mart model
        run_cmd("cd /app/dbt_models_duckdb && dbt deps")
        res_src = run_cmd("cd /app/dbt_models_duckdb && dbt run --select int_sales__orders_enriched")
        require(res_src.returncode == 0, "Failed to build int_sales__orders_enriched")

        # Drop existing target table if present (DuckDB only)
        import duckdb
        drop_conn = duckdb.connect(DB_PATH)
        for name in [
            "analytics.rpt_repeat_purchase_cohort_revenue_fixed",
            "ANALYTICS.rpt_repeat_purchase_cohort_revenue_fixed",
            "rpt_repeat_purchase_cohort_revenue_fixed",
        ]:
            try:
                drop_conn.execute(f"DROP TABLE IF EXISTS {name}")
            except Exception:
                pass
        drop_conn.close()

        # Run agent model
        res = run_cmd("cd /app/dbt_project && dbt run --select rpt_repeat_purchase_cohort_revenue_fixed --full-refresh")
        if res.returncode != 0:
            err = res.stderr or res.stdout
            require(False, f"dbt run failed: {err[:1500]}")


# ============ FIXTURE ============


@pytest.fixture(scope="module")
def conn():
    """Pytest fixture providing a database connection (DuckDB or Snowflake)."""
    require(os.path.exists(PROJECT_DIR), "dbt_project directory missing")
    require(os.path.exists(MODEL_PATH), f"Model missing: {MODEL_PATH}")
    run_dbt_pipeline()
    c, db_type = get_db_connection()
    yield c, db_type
    c.close()


# ============ TESTS ============


def test_schema_and_types(conn):
    """Test that output table has correct schema."""
    c, db_type = conn

    if db_type == 'snowflake':
        cols = execute_query(c, db_type, f"""
            SELECT LOWER(column_name), data_type
            FROM information_schema.columns
            WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
            AND LOWER(table_name) = 'rpt_repeat_purchase_cohort_revenue_fixed'
        """)
    else:
        cols = execute_query(c, db_type, f"""
            SELECT name, type
            FROM pragma_table_info('{SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed')
            ORDER BY cid
        """)

    expected = {
        "cohort_month": "DATE",
        "months_since_cohort": "INTEGER",
        "cohort_size": "INTEGER",
        "active_customers": "INTEGER",
        "orders": "INTEGER",
        "revenue": "DECIMAL",
        "cumulative_revenue": "DECIMAL",
    }
    names = {n.lower(): t for n, t in cols}
    missing = set(expected.keys()) - set(names.keys())
    require(not missing, f"Missing columns: {missing}")

    for col, typ in expected.items():
        actual = names[col].upper()
        if typ == "DATE":
            require("DATE" in actual, f"{col} should be DATE-like, got {actual}")
        elif typ == "INTEGER":
            require(any(k in actual for k in ("INT", "BIGINT", "NUMBER")), f"{col} should be INT-like, got {actual}")
        elif typ == "DECIMAL":
            require(any(k in actual for k in ("DECIMAL", "NUMERIC", "DOUBLE", "FLOAT", "NUMBER")), f"{col} should be numeric/decimal, got {actual}")


def test_nulls_bounds_and_monotonicity(conn):
    """Test basic constraints: no NULLs, non-negative values, monotonic cumulative."""
    c, db_type = conn

    row = execute_query(c, db_type, f"""
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN cohort_month IS NULL THEN 1 ELSE 0 END) AS null_cohort,
            SUM(CASE WHEN months_since_cohort IS NULL THEN 1 ELSE 0 END) AS null_msc,
            SUM(CASE WHEN months_since_cohort < 0 THEN 1 ELSE 0 END) AS neg_msc,
            SUM(CASE WHEN revenue < 0 THEN 1 ELSE 0 END) AS neg_rev,
            SUM(CASE WHEN cumulative_revenue < 0 THEN 1 ELSE 0 END) AS neg_cum,
            SUM(CASE WHEN cumulative_revenue < revenue THEN 1 ELSE 0 END) AS cum_lt_rev,
            SUM(CASE WHEN active_customers > cohort_size THEN 1 ELSE 0 END) AS bad_active
        FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
    """)[0]
    (
        total,
        null_cohort,
        null_msc,
        neg_msc,
        neg_rev,
        neg_cum,
        cum_lt_rev,
        bad_active,
    ) = [int(v) for v in row]
    require(total > 0, "No rows produced")
    require(null_cohort == 0, f"NULL cohort_month rows: {null_cohort}")
    require(null_msc == 0, f"NULL months_since_cohort rows: {null_msc}")
    require(neg_msc == 0, f"Negative months_since_cohort rows: {neg_msc}")
    require(neg_rev == 0, f"Negative revenue rows: {neg_rev}")
    require(neg_cum == 0, f"Negative cumulative_revenue rows: {neg_cum}")
    require(cum_lt_rev == 0, f"Rows where cumulative_revenue < revenue: {cum_lt_rev}")
    require(bad_active == 0, f"Rows where active_customers > cohort_size: {bad_active}")

    monotonic = execute_scalar(c, db_type, f"""
        WITH ordered AS (
            SELECT
                cohort_month,
                months_since_cohort,
                cumulative_revenue,
                LAG(cumulative_revenue) OVER (PARTITION BY cohort_month ORDER BY months_since_cohort) AS prev_cum
            FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
        )
        SELECT COUNT(*) FROM ordered WHERE prev_cum IS NOT NULL AND cumulative_revenue < prev_cum
    """)
    require(int(monotonic) == 0, f"Cumulative revenue decreased within cohort for {monotonic} rows")


def test_cohort_size_consistency(conn):
    """Test that cohort_size matches recomputed value from source."""
    c, db_type = conn

    if db_type == 'snowflake':
        diffs = execute_query(c, db_type, f"""
            WITH order_deduped AS (
                SELECT
                    order_id,
                    MIN(customer_id) AS customer_id,
                    MIN(CAST(ordered_at AS TIMESTAMP)) AS ordered_at
                FROM main.int_sales__orders_enriched
                WHERE ordered_at IS NOT NULL
                GROUP BY order_id
            ),
            first_order AS (
                SELECT
                    customer_id,
                    CAST(DATE_TRUNC('month', MIN(ordered_at)) AS DATE) AS cohort_month
                FROM order_deduped
                WHERE customer_id IS NOT NULL
                GROUP BY customer_id
            ),
            expected_cohort AS (
                SELECT cohort_month, COUNT(DISTINCT customer_id) AS expected_size
                FROM first_order
                GROUP BY cohort_month
            ),
            mart AS (
                SELECT cohort_month, cohort_size
                FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
                GROUP BY cohort_month, cohort_size
            )
            SELECT m.cohort_month, m.cohort_size, e.expected_size
            FROM mart m
            LEFT JOIN expected_cohort e ON m.cohort_month = e.cohort_month
            WHERE m.cohort_size != e.expected_size
        """)
    else:
        diffs = execute_query(c, db_type, f"""
            WITH first_order AS (
                SELECT
                    customer_id,
                    date_trunc('month', MIN(ordered_at))::date AS cohort_month
                FROM main.int_sales__orders_enriched
                WHERE ordered_at IS NOT NULL
                GROUP BY customer_id
            ),
            expected_cohort AS (
                SELECT cohort_month, COUNT(DISTINCT customer_id) AS expected_size
                FROM first_order
                GROUP BY cohort_month
            ),
            mart AS (
                SELECT cohort_month, cohort_size
                FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
                GROUP BY cohort_month, cohort_size
            )
            SELECT m.cohort_month, m.cohort_size, e.expected_size
            FROM mart m
            LEFT JOIN expected_cohort e USING (cohort_month)
            WHERE m.cohort_size != e.expected_size
        """)

    require(len(diffs) == 0, f"Cohort size mismatches: {diffs[:5]}")


def test_cumulative_equals_running_sum(conn):
    """Test that cumulative_revenue matches summed revenue across prior buckets."""
    c, db_type = conn

    bad = execute_scalar(c, db_type, f"""
        WITH base AS (
            SELECT cohort_month, months_since_cohort, revenue, cumulative_revenue
            FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
        ),
        recomputed AS (
            SELECT
                b.cohort_month,
                b.months_since_cohort,
                SUM(b2.revenue) AS recomputed_cum,
                b.cumulative_revenue
            FROM base b
            JOIN base b2
              ON b2.cohort_month = b.cohort_month
             AND b2.months_since_cohort <= b.months_since_cohort
            GROUP BY b.cohort_month, b.months_since_cohort, b.cumulative_revenue
        )
        SELECT COUNT(*) FROM recomputed
        WHERE ABS(COALESCE(recomputed_cum,0) - COALESCE(cumulative_revenue,0)) > 0.01
    """)
    require(int(bad) == 0, f"Cumulative revenue does not match summed revenue in {bad} buckets")


def test_reconciliation(conn):
    """Test that totals reconcile with source data."""
    c, db_type = conn

    if db_type == 'snowflake':
        src_row = execute_query(c, db_type, """
            SELECT
                COUNT(DISTINCT order_id) AS orders,
                SUM(CAST(grand_total AS DECIMAL(18,2))) AS revenue
            FROM main.int_sales__orders_enriched
            WHERE ordered_at IS NOT NULL
        """)
    else:
        src_row = execute_query(c, db_type, """
            SELECT
                COUNT(DISTINCT order_id) AS orders,
                SUM(CAST(grand_total AS DECIMAL(18,2))) AS revenue
            FROM main.int_sales__orders_enriched
            WHERE ordered_at IS NOT NULL
        """)

    src_orders, src_revenue = src_row[0]

    out_row = execute_query(c, db_type, f"""
        SELECT SUM(orders) AS orders, SUM(revenue) AS revenue
        FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
    """)

    out_orders, out_revenue = out_row[0]

    require(
        abs(int(out_orders) - int(src_orders)) <= 1,
        f"Order counts mismatch src={src_orders}, out={out_orders}"
    )
    revenue_diff = abs(float(out_revenue) - float(src_revenue))
    revenue_rel = revenue_diff / max(abs(float(src_revenue)), 1.0)
    require(
        revenue_rel <= 0.005,
        f"Revenue mismatch src={src_revenue}, out={out_revenue}, rel_diff={revenue_rel:.6f}"
    )


def test_idempotent_totals_stable(conn):
    """Test that rerunning the pipeline produces identical totals."""
    c, db_type = conn

    before = execute_query(c, db_type, f"""
        SELECT COUNT(*) AS row_count, SUM(orders) AS orders, SUM(revenue) AS revenue
        FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
    """)[0]

    # Close the connection to allow rebuild
    c.close()

    # Force rerun
    run_dbt_pipeline()

    c2, db_type2 = get_db_connection()
    try:
        after = execute_query(c2, db_type2, f"""
            SELECT COUNT(*) AS row_count, SUM(orders) AS orders, SUM(revenue) AS revenue
            FROM {SCHEMA}.rpt_repeat_purchase_cohort_revenue_fixed
        """)[0]
    finally:
        c2.close()

    require(
        int(before[0]) == int(after[0]),
        f"Rowcount changed after rerun: before={before[0]}, after={after[0]}"
    )
    require(
        abs(int(before[1]) - int(after[1])) <= 1,
        f"Orders changed after rerun: before={before[1]}, after={after[1]}"
    )
    require(
        abs(float(before[2]) - float(after[2])) <= 0.01,
        f"Revenue changed after rerun: before={before[2]}, after={after[2]}"
    )
