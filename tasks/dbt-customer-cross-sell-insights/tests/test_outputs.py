"""
Adversarial verifier for Advanced Customer Cross-Sell Insights -- Expert Mode.

Goals: validate schema/types, canonical pairs, guardrails, advanced metric math (support/confidence/lift/conviction/leverage/kulczynski/jaccard/cosine),
revenue weighting, temporal decay, customer segmentation, category hierarchies, and reconciliation to source.
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
        private_key_pem, password=passphrase_bytes, backend=default_backend()
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
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def get_db_connection_rw():
    """Create a read-write database connection (DuckDB only, for cleanup)."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return get_db_connection()
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path, read_only=False)
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


# ============ CONFIGURATION ============

SCHEMA = "analytics"
PROJECT_DIR = "/app/dbt_project"
MODEL1_PATH = "/app/dbt_project/models/marts/products/rpt_cross_sell_insights.sql"
MODEL2_PATH = "/app/dbt_project/models/marts/products/rpt_cross_sell_trends.sql"
MODEL3_PATH = "/app/dbt_project/models/marts/customer/rpt_cross_sell_by_segment.sql"
MODEL4_PATH = "/app/dbt_project/models/marts/products/rpt_cross_sell_category_hierarchy.sql"


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


def _source_tables_exist():
    """Check if the required source staging tables already exist in the database."""
    try:
        conn, db_type = get_db_connection()
        try:
            for table_name in ('int_sales__order_lines', 'int_sales__orders_enriched'):
                result = execute_query(conn, db_type, f"""
                    SELECT COUNT(*) FROM information_schema.tables
                    WHERE lower(table_name) = lower('{table_name}')
                """)
                if not result or int(result[0][0]) == 0:
                    return False
            return True
        finally:
            conn.close()
    except Exception:
        return False


def run_dbt_pipeline():
    """Build the complete dbt pipeline for cross-sell insights models."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    dbt_backend_dir = get_dbt_project_dir()

    # Build source models in the backend project only if they don't already exist
    if not _source_tables_exist():
        run_cmd(f"cd {dbt_backend_dir} && dbt deps")
        res = run_cmd(f"cd {dbt_backend_dir} && dbt run --select int_sales__order_lines int_sales__orders_enriched")
        require(res.returncode == 0, "Failed to build source tables")
    else:
        print("Source tables already exist, skipping backend dbt build")

    require(os.path.exists(PROJECT_DIR), "dbt_project directory missing")
    require(os.path.exists(MODEL1_PATH), f"Model 1 missing: {MODEL1_PATH}")
    require(os.path.exists(MODEL2_PATH), f"Model 2 missing: {MODEL2_PATH}")
    require(os.path.exists(MODEL3_PATH), f"Model 3 missing: {MODEL3_PATH}")
    require(os.path.exists(MODEL4_PATH), f"Model 4 missing: {MODEL4_PATH}")

    # Clean up existing analytics tables (DuckDB only - case sensitivity)
    if db_type == 'duckdb':
        conn_rw, ct = get_db_connection_rw()
        try:
            for schema_name in ("analytics", "ANALYTICS"):
                for rel in (
                    "rpt_cross_sell_insights",
                    "rpt_cross_sell_trends",
                    "rpt_cross_sell_by_segment",
                    "rpt_cross_sell_category_hierarchy",
                ):
                    try:
                        conn_rw.execute(f"DROP TABLE IF EXISTS {schema_name}.{rel}")
                    except Exception:
                        pass
        finally:
            conn_rw.close()

    res2 = run_cmd(
        f"cd {PROJECT_DIR} && export DBT_PROFILES_DIR={PROJECT_DIR} && "
        "dbt run --select rpt_cross_sell_insights rpt_cross_sell_trends "
        "rpt_cross_sell_by_segment rpt_cross_sell_category_hierarchy --full-refresh"
    )
    if res2.returncode != 0:
        err = res2.stderr or res2.stdout
        require(False, f"dbt run failed: {err[:1500]}")


@pytest.fixture(scope="module")
def db():
    """Pytest fixture providing a database connection and db_type."""
    run_dbt_pipeline()
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ========== HELPER: DATEDIFF expression ==========

def datediff_expr(db_type, unit, col_start, col_end):
    """Return a DATEDIFF expression compatible with the current backend."""
    if db_type == 'snowflake':
        return f"DATEDIFF({unit}, {col_start}, {col_end})"
    else:
        return f"DATEDIFF('{unit}', {col_start}, {col_end})"


# ========== MODEL 1 TESTS ==========

def test_model1_schema_and_types(db):
    """Verify rpt_cross_sell_insights has all required columns with correct data types."""
    conn, db_type = db
    cols = execute_query(conn, db_type, f"""
        SELECT lower(column_name), data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = lower('{SCHEMA}')
          AND lower(table_name) = 'rpt_cross_sell_insights'
    """)
    expected = {
        "sku_a": "VARCHAR",
        "sku_b": "VARCHAR",
        "orders_with_a": "INTEGER",
        "orders_with_b": "INTEGER",
        "orders_with_both": "INTEGER",
        "support": "DECIMAL",
        "confidence_a_to_b": "DECIMAL",
        "confidence_b_to_a": "DECIMAL",
        "lift_a_to_b": "DECIMAL",
        "lift_b_to_a": "DECIMAL",
        "conviction_a_to_b": "DECIMAL",
        "leverage_a_to_b": "DECIMAL",
        "kulczynski_measure": "DECIMAL",
        "jaccard_coefficient": "DECIMAL",
        "cosine_similarity": "DECIMAL",
        "avg_revenue_per_order_with_both": "DECIMAL",
        "total_revenue_with_both": "DECIMAL",
        "revenue_weighted_support": "DECIMAL",
        "avg_quantity_per_order_with_both": "DECIMAL",
        "max_orders_in_single_day": "INTEGER",
    }
    names = {n.lower(): t.upper() for n, t in cols}
    missing = set(expected.keys()) - set(names.keys())
    require(not missing, f"Missing columns: {missing}")
    for col, typ in expected.items():
        actual = names[col]
        if typ == "VARCHAR":
            require("VARCHAR" in actual or "TEXT" in actual or "CHAR" in actual, f"{col} should be VARCHAR-like, got {actual}")
        elif typ == "INTEGER":
            require(any(k in actual for k in ("INT", "BIGINT", "NUMBER")), f"{col} should be INT-like, got {actual}")
        elif typ == "DECIMAL":
            require(any(k in actual for k in ("DECIMAL", "NUMERIC", "DOUBLE", "FLOAT", "NUMBER")), f"{col} should be numeric, got {actual}")


def test_model1_canonical_and_guardrails(db):
    """Validate canonical pair ordering (sku_a < sku_b) and minimum threshold guardrails."""
    conn, db_type = db
    bad = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_insights
        WHERE sku_a IS NULL OR sku_b IS NULL OR sku_a >= sku_b
           OR orders_with_both > orders_with_a
           OR orders_with_both > orders_with_b
           OR orders_with_both < 0 OR orders_with_a < 0 OR orders_with_b < 0
           OR support < 0.005
           OR orders_with_both < 3
           OR jaccard_coefficient < 0.001
           OR jaccard_coefficient > 1.0
           OR cosine_similarity < 0.0 OR cosine_similarity > 1.0
           OR kulczynski_measure < 0.0 OR kulczynski_measure > 1.0
    """))
    require(bad == 0, f"Found {bad} rows violating canonical/guardrail/filtering rules")


def test_model1_advanced_metrics_math(db):
    """Verify kulczynski, jaccard, and cosine similarity calculations match their formulas."""
    conn, db_type = db
    checks = execute_query(conn, db_type, f"""
        SELECT
            COUNT(*) AS total,
            SUM(CASE
                WHEN ABS(kulczynski_measure - 0.5 * (confidence_a_to_b + confidence_b_to_a)) > 1e-5
                THEN 1 ELSE 0
            END) AS bad_kulczynski,
            SUM(CASE
                WHEN ABS(jaccard_coefficient - (CAST(orders_with_both AS DOUBLE) / NULLIF(orders_with_a + orders_with_b - orders_with_both, 0))) > 1e-5
                THEN 1 ELSE 0
            END) AS bad_jaccard,
            SUM(CASE
                WHEN ABS(cosine_similarity - (CAST(orders_with_both AS DOUBLE) / NULLIF(SQRT(CAST(orders_with_a AS DOUBLE) * CAST(orders_with_b AS DOUBLE)), 0))) > 1e-5
                THEN 1 ELSE 0
            END) AS bad_cosine
        FROM {SCHEMA}.rpt_cross_sell_insights
    """)
    total, bad_kulczynski, bad_jaccard, bad_cosine = [int(x) if x is not None else 0 for x in checks[0]]
    if total > 0:
        require(bad_kulczynski == 0, f"Kulczynski measure mismatches in {bad_kulczynski} rows")
        require(bad_jaccard == 0, f"Jaccard coefficient mismatches in {bad_jaccard} rows")
        require(bad_cosine == 0, f"Cosine similarity mismatches in {bad_cosine} rows")


def test_model1_revenue_and_quantity_metrics(db):
    """Reconcile avg/total revenue and avg quantity metrics against source order data."""
    conn, db_type = db

    # Build the is_cancelled filter for both backends
    cancel_filter = ("UPPER(CAST(o.is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')"
                     if db_type == 'snowflake'
                     else "COALESCE(o.is_cancelled, 0) = 0")

    checks = execute_query(conn, db_type, f"""
        WITH order_skus AS (
          SELECT DISTINCT ol.order_id, ol.sku
          FROM main.int_sales__order_lines ol
          JOIN main.int_sales__orders_enriched o ON o.order_id = ol.order_id
          WHERE ol.sku IS NOT NULL
            AND {cancel_filter}
        ),
        eligible_orders AS (
          SELECT order_id
          FROM order_skus
          GROUP BY order_id
          HAVING COUNT(DISTINCT sku) >= 2
        ),
        order_skus_filtered AS (
          SELECT os.order_id, os.sku
          FROM order_skus os
          JOIN eligible_orders eo ON eo.order_id = os.order_id
        ),
        pair_orders AS (
          SELECT
            LEAST(a.sku, b.sku) AS sku_a,
            GREATEST(a.sku, b.sku) AS sku_b,
            a.order_id
          FROM order_skus_filtered a
          JOIN order_skus_filtered b ON a.order_id = b.order_id AND a.sku < b.sku
        ),
        revenue_data AS (
          SELECT
            r.sku_a,
            r.sku_b,
            COUNT(DISTINCT o.order_id) AS actual_orders,
            SUM(o.grand_total) AS actual_total_revenue,
            AVG(o.grand_total) AS actual_avg_revenue,
            AVG(order_qty.total_qty) AS actual_avg_qty
          FROM {SCHEMA}.rpt_cross_sell_insights r
          JOIN pair_orders p ON p.sku_a = r.sku_a AND p.sku_b = r.sku_b
          JOIN main.int_sales__orders_enriched o ON o.order_id = p.order_id
          JOIN (
            SELECT order_id, SUM(quantity_ordered) AS total_qty
            FROM main.int_sales__order_lines
            GROUP BY order_id
          ) order_qty ON order_qty.order_id = o.order_id
          WHERE {cancel_filter}
          GROUP BY 1, 2
        )
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN ABS(avg_revenue_per_order_with_both - actual_avg_revenue) > 0.01 THEN 1 ELSE 0 END) AS bad_avg_rev,
            SUM(CASE WHEN ABS(total_revenue_with_both - actual_total_revenue) > 0.01 THEN 1 ELSE 0 END) AS bad_total_rev,
            SUM(CASE WHEN ABS(avg_quantity_per_order_with_both - actual_avg_qty) > 0.01 THEN 1 ELSE 0 END) AS bad_avg_qty
        FROM {SCHEMA}.rpt_cross_sell_insights r
        JOIN revenue_data rd ON rd.sku_a = r.sku_a AND rd.sku_b = r.sku_b
    """)
    total, bad_avg_rev, bad_total_rev, bad_avg_qty = [int(x) if x is not None else 0 for x in checks[0]]
    if total > 0:
        require(bad_avg_rev == 0, f"Average revenue mismatches in {bad_avg_rev} rows")
        require(bad_total_rev == 0, f"Total revenue mismatches in {bad_total_rev} rows")
        require(bad_avg_qty == 0, f"Average quantity mismatches in {bad_avg_qty} rows")


def test_model1_max_orders_single_day(db):
    """Verify max_orders_in_single_day matches the actual maximum daily co-occurrence count."""
    conn, db_type = db

    cancel_filter = ("UPPER(CAST(o.is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')"
                     if db_type == 'snowflake'
                     else "COALESCE(o.is_cancelled, 0) = 0")

    bad = int(execute_scalar(conn, db_type, f"""
        WITH order_skus AS (
          SELECT DISTINCT ol.order_id, ol.sku, CAST(o.ordered_at AS DATE) AS order_date
          FROM main.int_sales__order_lines ol
          JOIN main.int_sales__orders_enriched o ON o.order_id = ol.order_id
          WHERE ol.sku IS NOT NULL
            AND {cancel_filter}
        ),
        eligible_orders AS (
          SELECT order_id
          FROM order_skus
          GROUP BY order_id
          HAVING COUNT(DISTINCT sku) >= 2
        ),
        order_skus_filtered AS (
          SELECT os.order_id, os.sku, os.order_date
          FROM order_skus os
          JOIN eligible_orders eo ON eo.order_id = os.order_id
        ),
        pair_daily_counts AS (
          SELECT
            LEAST(a.sku, b.sku) AS sku_a,
            GREATEST(a.sku, b.sku) AS sku_b,
            a.order_date,
            COUNT(DISTINCT a.order_id) AS daily_orders
          FROM order_skus_filtered a
          JOIN order_skus_filtered b ON a.order_id = b.order_id AND a.sku < b.sku
          GROUP BY 1, 2, 3
        ),
        max_daily AS (
          SELECT sku_a, sku_b, MAX(daily_orders) AS max_daily_orders
          FROM pair_daily_counts
          GROUP BY 1, 2
        )
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_insights r
        JOIN max_daily m ON m.sku_a = r.sku_a AND m.sku_b = r.sku_b
        WHERE r.max_orders_in_single_day != m.max_daily_orders
    """))
    require(bad == 0, f"Found {bad} rows with incorrect max_orders_in_single_day")


# ========== MODEL 2 TESTS ==========

def test_model2_schema_and_types(db):
    """Verify rpt_cross_sell_trends has all required columns with correct data types."""
    conn, db_type = db
    cols = execute_query(conn, db_type, f"""
        SELECT lower(column_name), data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = lower('{SCHEMA}')
          AND lower(table_name) = 'rpt_cross_sell_trends'
    """)
    expected = {
        "sku_a": "VARCHAR",
        "sku_b": "VARCHAR",
        "year": "INTEGER",
        "quarter": "INTEGER",
        "month": "INTEGER",
        "orders_with_both": "INTEGER",
        "support": "DECIMAL",
        "confidence_a_to_b": "DECIMAL",
        "lift_a_to_b": "DECIMAL",
        "quarter_over_quarter_change": "DECIMAL",
        "month_over_month_change": "DECIMAL",
        "exponential_decay_weight": "DECIMAL",
        "decay_weighted_support": "DECIMAL",
    }
    names = {n.lower(): t.upper() for n, t in cols}
    missing = set(expected.keys()) - set(names.keys())
    require(not missing, f"Missing columns: {missing}")


def test_model2_period_validity(db):
    """Check that year/quarter/month values are valid and decay weights are in (0, 1]."""
    conn, db_type = db
    bad = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_trends
        WHERE quarter NOT IN (1, 2, 3, 4)
           OR month NOT BETWEEN 1 AND 12
           OR year < 2000 OR year > 2100
           OR sku_a IS NULL OR sku_b IS NULL OR sku_a >= sku_b
           OR exponential_decay_weight <= 0 OR exponential_decay_weight > 1.0
    """))
    require(bad == 0, f"Found {bad} rows with invalid period/decay or canonical violations")


def test_model2_pairs_exist_in_model1(db):
    """Ensure all SKU pairs in trends model also exist in the insights model."""
    conn, db_type = db
    missing = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT CONCAT(t.sku_a, '|', t.sku_b))
        FROM {SCHEMA}.rpt_cross_sell_trends t
        LEFT JOIN {SCHEMA}.rpt_cross_sell_insights i
          ON t.sku_a = i.sku_a AND t.sku_b = i.sku_b
        WHERE i.sku_a IS NULL
    """))
    require(missing == 0, f"Found {missing} pairs in Model 2 that don't exist in Model 1")


def test_model2_temporal_metrics(db):
    """Validate quarter-over-quarter and month-over-month change calculations."""
    conn, db_type = db
    checks = execute_query(conn, db_type, f"""
        WITH quarterly_data AS (
          SELECT
            t.sku_a,
            t.sku_b,
            t.year,
            t.quarter,
            t.month,
            t.support,
            t.quarter_over_quarter_change,
            t.month_over_month_change,
            LAG(t.support) OVER (PARTITION BY t.sku_a, t.sku_b ORDER BY t.year, t.quarter, t.month) AS prev_support,
            LAG(t.support) OVER (PARTITION BY t.sku_a, t.sku_b, t.year ORDER BY t.quarter, t.month) AS prev_quarter_support
          FROM {SCHEMA}.rpt_cross_sell_trends t
        )
        SELECT
            COUNT(*) AS total,
            SUM(CASE
                WHEN qd.quarter = 1 AND qd.quarter_over_quarter_change IS NOT NULL THEN 1
                WHEN qd.prev_quarter_support IS NULL AND qd.quarter_over_quarter_change IS NOT NULL AND qd.quarter > 1 THEN 1
                WHEN qd.prev_quarter_support IS NOT NULL AND qd.quarter > 1 AND
                     ABS(qd.quarter_over_quarter_change - ((qd.support - qd.prev_quarter_support) / NULLIF(qd.prev_quarter_support, 0))) > 1e-3
                THEN 1
                ELSE 0
            END) AS bad_qoq,
            SUM(CASE
                WHEN qd.month = 1 AND qd.year = (SELECT MIN(year) FROM {SCHEMA}.rpt_cross_sell_trends) AND qd.month_over_month_change IS NOT NULL THEN 1
                WHEN qd.prev_support IS NULL AND qd.month_over_month_change IS NOT NULL AND qd.month > 1 THEN 1
                WHEN qd.prev_support IS NOT NULL AND qd.month > 1 AND
                     ABS(qd.month_over_month_change - ((qd.support - qd.prev_support) / NULLIF(qd.prev_support, 0))) > 1e-3
                THEN 1
                ELSE 0
            END) AS bad_mom
        FROM quarterly_data qd
    """)
    total, bad_qoq, bad_mom = [int(x) if x is not None else 0 for x in checks[0]]
    if total > 0:
        require(bad_qoq == 0, f"Quarter-over-quarter change mismatches in {bad_qoq} rows")
        require(bad_mom == 0, f"Month-over-month change mismatches in {bad_mom} rows")


def test_model2_decay_weighted_support(db):
    """Verify decay_weighted_support equals support * exponential_decay_weight."""
    conn, db_type = db
    bad = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_trends
        WHERE ABS(decay_weighted_support - (support * exponential_decay_weight)) > 1e-6
    """))
    require(bad == 0, f"Found {bad} rows with incorrect decay_weighted_support")


# ========== MODEL 3 TESTS ==========

def test_model3_schema_and_types(db):
    """Verify rpt_cross_sell_by_segment has all required columns with correct data types."""
    conn, db_type = db
    cols = execute_query(conn, db_type, f"""
        SELECT lower(column_name), data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = lower('{SCHEMA}')
          AND lower(table_name) = 'rpt_cross_sell_by_segment'
    """)
    expected = {
        "customer_segment": "VARCHAR",
        "sku_a": "VARCHAR",
        "sku_b": "VARCHAR",
        "orders_with_both": "INTEGER",
        "support": "DECIMAL",
        "confidence_a_to_b": "DECIMAL",
        "lift_a_to_b": "DECIMAL",
        "avg_order_value_with_both": "DECIMAL",
        "category_a": "VARCHAR",
        "category_b": "VARCHAR",
        "same_category_flag": "BOOLEAN",
        "cross_category_lift": "DECIMAL",
    }
    names = {n.lower(): t.upper() for n, t in cols}
    missing = set(expected.keys()) - set(names.keys())
    require(not missing, f"Missing columns: {missing}")


def test_model3_segment_validity(db):
    """Validate customer segment values, canonical pair ordering, and category flag logic."""
    conn, db_type = db

    # For same_category_flag, use integer comparison (1/0) which works on both backends
    bad = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_by_segment
        WHERE customer_segment NOT IN ('high_value', 'medium_value', 'low_value', 'new', 'unknown')
           OR sku_a IS NULL OR sku_b IS NULL OR sku_a >= sku_b
           OR (same_category_flag = 1 AND cross_category_lift IS NOT NULL)
           OR (same_category_flag = 0 AND cross_category_lift IS NULL AND lift_a_to_b IS NOT NULL
               AND category_a IS NOT NULL AND category_b IS NOT NULL AND category_a != category_b)
    """))
    require(bad == 0, f"Found {bad} rows with invalid segment/category logic or canonical violations")


def test_model3_pairs_exist_in_model1(db):
    """Ensure all SKU pairs in the segment model also exist in the insights model."""
    conn, db_type = db
    missing = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT CONCAT(s.sku_a, '|', s.sku_b))
        FROM {SCHEMA}.rpt_cross_sell_by_segment s
        LEFT JOIN {SCHEMA}.rpt_cross_sell_insights i
          ON s.sku_a = i.sku_a AND s.sku_b = i.sku_b
        WHERE i.sku_a IS NULL
    """))
    require(missing == 0, f"Found {missing} pairs in Model 3 that don't exist in Model 1")


def test_model3_same_category_flag(db):
    """Verify same_category_flag is 1 when categories match and 0 otherwise."""
    conn, db_type = db
    bad = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_by_segment
        WHERE (category_a = category_b AND category_a IS NOT NULL AND same_category_flag != 1)
           OR (category_a != category_b AND category_a IS NOT NULL AND category_b IS NOT NULL AND same_category_flag != 0)
           OR ((category_a IS NULL OR category_b IS NULL) AND same_category_flag != 0)
    """))
    require(bad == 0, f"Found {bad} rows with incorrect same_category_flag logic")


# ========== MODEL 4 TESTS ==========

def test_model4_schema_and_types(db):
    """Verify rpt_cross_sell_category_hierarchy has all required columns with correct data types."""
    conn, db_type = db
    cols = execute_query(conn, db_type, f"""
        SELECT lower(column_name), data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = lower('{SCHEMA}')
          AND lower(table_name) = 'rpt_cross_sell_category_hierarchy'
    """)
    expected = {
        "category_a": "VARCHAR",
        "category_b": "VARCHAR",
        "orders_with_category_a": "INTEGER",
        "orders_with_category_b": "INTEGER",
        "orders_with_both_categories": "INTEGER",
        "category_support": "DECIMAL",
        "category_confidence_a_to_b": "DECIMAL",
        "category_lift_a_to_b": "DECIMAL",
        "avg_skus_per_order_with_both": "DECIMAL",
        "total_revenue_with_both_categories": "DECIMAL",
    }
    names = {n.lower(): t.upper() for n, t in cols}
    missing = set(expected.keys()) - set(names.keys())
    require(not missing, f"Missing columns: {missing}")


def test_model4_category_validity(db):
    """Check for null categories, canonical ordering, and minimum support/count thresholds."""
    conn, db_type = db
    bad = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_cross_sell_category_hierarchy
        WHERE category_a IS NULL OR category_b IS NULL
           OR category_a >= category_b
           OR category_support < 0.01
           OR orders_with_both_categories < 5
    """))
    require(bad == 0, f"Found {bad} rows with invalid categories or filtering violations")


def test_model4_category_metrics_math(db):
    """Reconcile category_support and category_confidence calculations against source data."""
    conn, db_type = db

    cancel_filter = ("UPPER(CAST(o.is_cancelled AS VARCHAR)) NOT IN ('1','TRUE','T','Y','YES')"
                     if db_type == 'snowflake'
                     else "COALESCE(o.is_cancelled, 0) = 0")

    checks = execute_query(conn, db_type, f"""
        WITH order_skus AS (
          SELECT DISTINCT ol.order_id, ol.sku
          FROM main.int_sales__order_lines ol
          JOIN main.int_sales__orders_enriched o ON o.order_id = ol.order_id
          WHERE ol.sku IS NOT NULL
            AND {cancel_filter}
        ),
        eligible_orders AS (
          SELECT order_id
          FROM order_skus
          GROUP BY order_id
          HAVING COUNT(DISTINCT sku) >= 2
        ),
        eligible_orders_count AS (
          SELECT COUNT(DISTINCT order_id) AS total
          FROM eligible_orders
        )
        SELECT
            COUNT(*) AS total,
            SUM(CASE
                WHEN ABS(c.category_support - (CAST(c.orders_with_both_categories AS DOUBLE) / NULLIF((SELECT total FROM eligible_orders_count), 0))) > 1e-5
                THEN 1 ELSE 0
            END) AS bad_support,
            SUM(CASE
                WHEN ABS(c.category_confidence_a_to_b - (CAST(c.orders_with_both_categories AS DOUBLE) / NULLIF(c.orders_with_category_a, 0))) > 1e-5
                THEN 1 ELSE 0
            END) AS bad_confidence
        FROM {SCHEMA}.rpt_cross_sell_category_hierarchy c
    """)
    total, bad_support, bad_confidence = [int(x) if x is not None else 0 for x in checks[0]]
    if total > 0:
        require(bad_support == 0, f"Category support mismatches in {bad_support} rows")
        require(bad_confidence == 0, f"Category confidence mismatches in {bad_confidence} rows")


# ========== IDEMPOTENCY TEST ==========

def test_idempotent_totals_stable(db):
    """Verify row counts across all four models remain stable after a second dbt run."""
    conn, db_type = db
    initial = execute_query(conn, db_type, f"""
        SELECT
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_insights),
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_trends),
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_by_segment),
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_category_hierarchy)
    """)
    initial_counts = tuple(int(x) for x in initial[0])

    run_cmd(
        f"cd {PROJECT_DIR} && export DBT_PROFILES_DIR={PROJECT_DIR} && "
        "dbt run --select rpt_cross_sell_insights rpt_cross_sell_trends "
        "rpt_cross_sell_by_segment rpt_cross_sell_category_hierarchy"
    )

    # Need a fresh connection for DuckDB read-only
    if db_type == 'duckdb':
        conn.close()
        conn2, db_type2 = get_db_connection()
    else:
        conn2, db_type2 = conn, db_type

    after = execute_query(conn2, db_type2, f"""
        SELECT
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_insights),
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_trends),
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_by_segment),
            (SELECT COUNT(*) FROM {SCHEMA}.rpt_cross_sell_category_hierarchy)
    """)
    after_counts = tuple(int(x) for x in after[0])

    require(initial_counts == after_counts, f"Idempotency failed: initial {initial_counts} != after {after_counts}")
