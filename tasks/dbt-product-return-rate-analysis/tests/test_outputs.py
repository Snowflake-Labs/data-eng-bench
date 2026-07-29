"""
Verifier for Product Return Rate Analysis task.

Validates schema, data quality, business logic, and reconciliation with source data.
Tests staging, intermediate, and mart models with advanced metrics.
"""
import os
import subprocess

import pytest


DB_PATH = "/app/database/retail.duckdb"
PROJECT_DIR = "/app/dbt_project"
STAGING_MODEL = "/app/dbt_project/models/staging/stg_product_returns.sql"
INTERMEDIATE_MODEL = "/app/dbt_project/models/intermediate/int_product_return_metrics.sql"
MART_MODEL = "/app/dbt_project/models/marts/product/rpt_product_return_rates_monthly.sql"


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
            schema='ANALYTICS',
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')




def run_cmd(cmd: str, cwd: str = "/app") -> subprocess.CompletedProcess:
    res = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if res.stdout:
        print(f"STDOUT: {res.stdout[:2000]}")
    if res.stderr:
        print(f"STDERR: {res.stderr[:1200]}")
    return res


def require(cond: bool, msg: str):
    if not cond:
        raise AssertionError(msg)


def _write_profiles():
    """Ensure ~/.dbt/profiles.yml has retail_dw_master and common profile names agents use.
    Each analytics profile points to /app/database/retail.duckdb with schema: analytics.
    Supports: dbt_project, retail_analytics, product_returns, default."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        # Snowflake profiles are managed by solve.sh
        return

    path = os.path.expanduser("~/.dbt/profiles.yml")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    dev_analytics = """
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: analytics
"""
    content = f"""retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb

dbt_project:{dev_analytics}
retail_analytics:{dev_analytics}
product_returns:{dev_analytics}
default:{dev_analytics}
"""
    with open(path, "w") as f:
        f.write(content)


def run_dbt_pipeline():
    """Build upstream models, then run the agent's models."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    _write_profiles()

    run_cmd(f"cd {get_dbt_project_dir()} && dbt deps", cwd="/app")
    res = run_cmd(
        f"cd {get_dbt_project_dir()} && dbt run --select int_sales__orders_enriched int_sales__order_lines",
        cwd="/app",
    )
    require(res.returncode == 0, f"Failed to build int_sales__orders_enriched and int_sales__order_lines: {(res.stderr or res.stdout)[:1500]}")

    if db_type == 'duckdb':
        import duckdb
        conn = duckdb.connect(DB_PATH)
        try:
            for name in (
                "analytics.rpt_product_return_rates_monthly",
                "ANALYTICS.rpt_product_return_rates_monthly",
                "analytics.int_product_return_metrics",
                "ANALYTICS.int_product_return_metrics",
            ):
                try:
                    conn.execute(f"DROP TABLE IF EXISTS {name}")
                except Exception:
                    pass
            for name in (
                "analytics.stg_product_returns",
                "ANALYTICS.stg_product_returns",
            ):
                try:
                    conn.execute(f"DROP VIEW IF EXISTS {name}")
                except Exception:
                    pass
        finally:
            conn.close()

    res = run_cmd("dbt run --select +rpt_product_return_rates_monthly --full-refresh", cwd=PROJECT_DIR)
    require(res.returncode == 0, f"dbt run failed: {(res.stderr or res.stdout)[:1500]}")


@pytest.fixture(scope="module")
def conn():
    require(os.path.isdir(PROJECT_DIR), "dbt_project directory missing")
    require(os.path.isfile(STAGING_MODEL), f"Staging model missing: {STAGING_MODEL}")
    require(os.path.isfile(INTERMEDIATE_MODEL), f"Intermediate model missing: {INTERMEDIATE_MODEL}")
    require(os.path.isfile(MART_MODEL), f"Mart model missing: {MART_MODEL}")
    run_dbt_pipeline()
    c, db_type = get_db_connection()
    yield c, db_type
    c.close()


def test_staging_model_exists(conn):
    """Staging model exists as view."""
    c, db_type = conn
    views = execute_query(c, db_type,
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE LOWER(table_schema) = 'analytics' AND LOWER(table_name) = 'stg_product_returns'
        """
    )
    require(len(views) > 0, "stg_product_returns view does not exist")


def test_intermediate_model_exists(conn):
    """Intermediate model exists as table."""
    c, db_type = conn
    tables = execute_query(c, db_type,
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE LOWER(table_schema) = 'analytics' AND LOWER(table_name) = 'int_product_return_metrics'
        """
    )
    require(len(tables) > 0, "int_product_return_metrics table does not exist")


def test_mart_table_exists(conn):
    """Output table exists in analytics schema."""
    c, db_type = conn
    tables = execute_query(c, db_type,
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE LOWER(table_schema) = 'analytics' AND LOWER(table_name) = 'rpt_product_return_rates_monthly'
        """
    )
    require(len(tables) > 0, "rpt_product_return_rates_monthly table does not exist")


def test_mart_schema(conn):
    """Mart table has correct schema with all required columns."""
    c, db_type = conn
    if db_type == 'snowflake':
        cols = execute_query(c, db_type,
            """
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE LOWER(table_schema) = 'analytics' AND LOWER(table_name) = 'rpt_product_return_rates_monthly'
            ORDER BY ordinal_position
            """
        )
    else:
        cols = execute_query(c, db_type,
            """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_product_return_rates_monthly')
            ORDER BY cid
            """
        )
    col_dict = {c[0].lower(): c[1].upper() for c in cols}

    required = {
        "month_start", "product_id", "sku", "units_ordered", "units_returned",
        "return_rate", "return_revenue_impact", "customers_affected",
        "avg_days_to_return", "p25_days_to_return", "p50_days_to_return", "p75_days_to_return",
        "p25_return_rate", "p50_return_rate", "p75_return_rate",
        "fast_returns", "medium_returns", "slow_returns",
        "fast_return_rate", "medium_return_rate", "slow_return_rate",
        "top_return_reason", "return_reason_count",
        "prev_month_return_rate", "mom_return_rate_change", "mom_return_rate_change_pct",
        "first_return_month", "months_since_first_return", "is_first_return_month",
    }
    missing = required - set(col_dict.keys())
    require(not missing, f"Missing required columns: {missing}")


def test_return_rate_logic(conn):
    """Return rates are consistent: returned <= ordered, and rate in [0,1]."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE units_returned > units_ordered
           OR return_rate < 0 OR return_rate > 1
           OR (units_ordered > 0 AND units_returned = 0 AND return_rate != 0)
           OR (units_ordered > 0 AND units_returned > 0 AND ABS(return_rate - (CAST(units_returned AS NUMERIC) / CAST(units_ordered AS NUMERIC))) > 0.000001)
        """
    )
    require(invalid == 0, f"Return rate logic violated in {invalid} rows")


def test_no_returns_handling(conn):
    """When no returns exist, return_rate=0, top_return_reason=NULL, return_reason_count=0, all days metrics=NULL."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE units_returned = 0
          AND (
              return_rate != 0
              OR top_return_reason IS NOT NULL
              OR return_reason_count != 0
              OR avg_days_to_return IS NOT NULL
              OR p25_days_to_return IS NOT NULL
              OR p50_days_to_return IS NOT NULL
              OR p75_days_to_return IS NOT NULL
              OR fast_returns != 0
              OR medium_returns != 0
              OR slow_returns != 0
          )
        """
    )
    require(invalid == 0, f"No-returns handling violated in {invalid} rows")


def test_percentile_ordering(conn):
    """Percentiles are ordered correctly: p25 <= p50 <= p75."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE units_returned > 0
          AND (
              (p25_days_to_return IS NOT NULL AND p50_days_to_return IS NOT NULL AND p25_days_to_return > p50_days_to_return)
              OR (p50_days_to_return IS NOT NULL AND p75_days_to_return IS NOT NULL AND p50_days_to_return > p75_days_to_return)
              OR (p25_return_rate IS NOT NULL AND p50_return_rate IS NOT NULL AND p25_return_rate > p50_return_rate)
              OR (p50_return_rate IS NOT NULL AND p75_return_rate IS NOT NULL AND p50_return_rate > p75_return_rate)
          )
        """
    )
    require(invalid == 0, f"Percentile ordering violated in {invalid} rows")


def test_return_velocity_rates(conn):
    """Return velocity rates sum to 1.0 when units_returned > 0."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE units_returned > 0
          AND ABS((fast_return_rate + medium_return_rate + slow_return_rate) - 1.0) > 0.0001
        """
    )
    require(invalid == 0, f"Return velocity rates don't sum to 1.0 in {invalid} rows")


def test_trend_metrics(conn):
    """Trend metrics are calculated correctly."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE prev_month_return_rate IS NOT NULL
          AND ABS(mom_return_rate_change - (return_rate - prev_month_return_rate)) > 0.000001
        """
    )
    require(invalid == 0, f"Trend metrics calculation violated in {invalid} rows")


def test_cohort_metrics(conn):
    """Cohort metrics are consistent."""
    c, db_type = conn
    # Use DATEDIFF for Snowflake, DATE_DIFF for DuckDB
    if db_type == 'snowflake':
        query = """
            SELECT COUNT(*) AS n
            FROM analytics.rpt_product_return_rates_monthly
            WHERE first_return_month IS NOT NULL
              AND months_since_first_return IS NOT NULL
              AND months_since_first_return != DATEDIFF('month', first_return_month, month_start)
            """
    else:
        query = """
            SELECT COUNT(*) AS n
            FROM analytics.rpt_product_return_rates_monthly
            WHERE first_return_month IS NOT NULL
              AND months_since_first_return IS NOT NULL
              AND months_since_first_return != DATE_DIFF('month', first_return_month, month_start)
            """
    invalid = execute_scalar(c, db_type, query)
    require(invalid == 0, f"Cohort metrics violated in {invalid} rows")


def test_is_first_return_month_logic(conn):
    """is_first_return_month is TRUE only when month_start = first_return_month."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE (is_first_return_month = TRUE AND month_start != first_return_month)
           OR (is_first_return_month = FALSE AND month_start = first_return_month AND first_return_month IS NOT NULL)
        """
    )
    require(invalid == 0, f"is_first_return_month logic violated in {invalid} rows")


def test_reconciliation_source(conn):
    """Output total units_ordered reconciles with source."""
    c, db_type = conn
    src = execute_scalar(c, db_type,
        """
        SELECT SUM(ol.quantity_ordered) AS total
        FROM main.int_sales__order_lines ol
        INNER JOIN main.int_sales__orders_enriched o ON ol.order_id = o.order_id
        WHERE ol.product_id IS NOT NULL AND o.status NOT IN ('CANCELLED', 'FAILED')
        """
    )

    out = execute_scalar(c, db_type,
        "SELECT SUM(units_ordered) FROM analytics.rpt_product_return_rates_monthly"
    )

    if src and out:
        diff = abs(src - out) / max(src, out)
        require(diff <= 0.05, f"Source reconciliation: source={src}, output={out}, diff={diff*100:.2f}%")


def test_return_reconciliation(conn):
    """Output total units_returned reconciles with source RETURN_LINES."""
    c, db_type = conn
    src = execute_scalar(c, db_type,
        """
        SELECT SUM(rl.quantity_returned) AS total
        FROM "ORDERS"."RETURN_LINES" rl
        INNER JOIN main.int_sales__order_lines ol ON rl.order_line_id = ol.order_line_id
        INNER JOIN main.int_sales__orders_enriched o ON ol.order_id = o.order_id
        WHERE ol.product_id IS NOT NULL
          AND o.status NOT IN ('CANCELLED', 'FAILED')
          AND rl.quantity_returned > 0
        """
    )

    out = execute_scalar(c, db_type,
        "SELECT SUM(units_returned) FROM analytics.rpt_product_return_rates_monthly"
    )

    if src and out:
        diff = abs(src - out) / max(src, out)
        require(diff <= 0.10, f"Return reconciliation: source={src}, output={out}, diff={diff*100:.2f}%")


def test_top_return_reason_logic(conn):
    """When units_returned > 0, top_return_reason and return_reason_count are non-NULL and return_reason_count > 0."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE units_returned > 0
          AND (
              top_return_reason IS NULL
              OR return_reason_count IS NULL
              OR return_reason_count <= 0
              OR return_reason_count > units_returned
          )
        """
    )
    require(invalid == 0, f"Top return reason logic violated in {invalid} rows")


def test_customers_affected_logic(conn):
    """customers_affected >= 0."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        "SELECT COUNT(*) FROM analytics.rpt_product_return_rates_monthly WHERE customers_affected < 0"
    )
    require(invalid == 0, f"customers_affected < 0 in {invalid} rows")


def test_sku_fallback(conn):
    """SKU is never NULL (product_id fallback when source sku is NULL)."""
    c, db_type = conn
    null_sku = execute_scalar(c, db_type,
        "SELECT COUNT(*) FROM analytics.rpt_product_return_rates_monthly WHERE sku IS NULL"
    )
    require(null_sku == 0, f"NULL sku in {null_sku} rows")


def test_revenue_impact_logic(conn):
    """return_revenue_impact is 0 when no returns, non-negative when returns exist."""
    c, db_type = conn
    invalid = execute_scalar(c, db_type,
        """
        SELECT COUNT(*) AS n
        FROM analytics.rpt_product_return_rates_monthly
        WHERE (units_returned = 0 AND return_revenue_impact != 0)
           OR (units_returned > 0 AND return_revenue_impact < 0)
        """
    )
    require(invalid == 0, f"return_revenue_impact logic violated in {invalid} rows")
