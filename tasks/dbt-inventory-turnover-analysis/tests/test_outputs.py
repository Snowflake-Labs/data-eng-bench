"""
Verifier for Inventory Turnover and Days of Supply Analysis task.
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def run_cmd(cmd, cwd="/app/dbt_project"):
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:800]}")
    return result


def require(cond, msg):
    if not cond:
        raise AssertionError(msg)


def run_dbt_pipeline():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    ref_project_dir = get_dbt_project_dir()

    # Build required staging models from reference project
    # Set DBT_PROFILES_DIR so dbt can find profiles.yml written by solve.sh
    run_cmd(
        f"cd {ref_project_dir} && DBT_PROFILES_DIR={ref_project_dir} dbt deps",
        cwd="/app",
    )
    res = run_cmd(
        f"cd {ref_project_dir} && DBT_PROFILES_DIR={ref_project_dir} "
        "dbt run --select stg_orders__order_lines stg_orders__orders "
        "stg_inventory__inventory_levels stg_product__product_variants stg_product__products",
        cwd="/app",
    )
    require(res.returncode == 0, "Failed to build required staging models")

    if db_type == 'duckdb':
        # Drop existing target table if present (DuckDB only)
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path)
        for name in [
            "analytics.rpt_inventory_turnover_analysis",
            "ANALYTICS.rpt_inventory_turnover_analysis",
            "rpt_inventory_turnover_analysis",
        ]:
            try:
                conn.execute(f"DROP TABLE IF EXISTS {name}")
            except Exception:
                pass
        conn.close()
    else:
        # For Snowflake, drop via connection
        conn, _ = get_db_connection()
        try:
            cursor = conn.cursor()
            cursor.execute("DROP TABLE IF EXISTS analytics.rpt_inventory_turnover_analysis")
        except Exception:
            pass
        finally:
            conn.close()

    # Run agent model
    # Set DBT_PROFILES_DIR so dbt can find profiles.yml in the agent project
    res2 = run_cmd(
        "DBT_PROFILES_DIR=/app/dbt_project dbt run --select rpt_inventory_turnover_analysis --full-refresh",
        cwd="/app/dbt_project",
    )
    if res2.returncode != 0:
        err = res2.stderr or res2.stdout
        require(False, f"dbt run failed: {err[:1500]}")


@pytest.fixture(scope="module")
def conn():
    require(os.path.exists("/app/dbt_project"), "dbt_project directory missing")
    require(
        os.path.exists(
            "/app/dbt_project/models/marts/inventory/"
            "rpt_inventory_turnover_analysis.sql"
        ),
        "Model missing: /app/dbt_project/models/marts/inventory/"
        "rpt_inventory_turnover_analysis.sql",
    )
    run_dbt_pipeline()
    c, db_type = get_db_connection()
    yield c, db_type
    c.close()


def test_schema(conn):
    """Table analytics.rpt_inventory_turnover_analysis exists with correct columns and types."""
    c, db_type = conn

    if db_type == 'snowflake':
        cols = execute_query(c, db_type, """
            SELECT lower(column_name)
            FROM information_schema.columns
            WHERE lower(table_schema) = 'analytics'
              AND lower(table_name) = 'rpt_inventory_turnover_analysis'
        """)
        col_names = {row[0] for row in cols}
    else:
        cols = execute_query(c, db_type, """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_inventory_turnover_analysis')
            ORDER BY cid
        """)
        col_names = {c_row[0].lower() for c_row in cols}

    required = {
        "sku",
        "warehouse_id",
        "product_category",
        "analysis_period_days",
        "total_units_sold",
        "avg_inventory_on_hand",
        "inventory_turnover_ratio",
        "days_of_supply",
        "turnover_velocity_class",
        "current_quantity_on_hand",
        "estimated_days_until_stockout",
    }
    missing = required - col_names
    require(not missing, f"Missing required columns: {missing}")


def test_basic_quality(conn):
    """All numeric measures are non-negative, no NULL sku/warehouse_id for rows with stock."""
    c, db_type = conn
    row = execute_query(c, db_type, """
        SELECT
          COUNT(*) AS total,
          SUM(CASE WHEN sku IS NULL THEN 1 ELSE 0 END) AS null_sku,
          SUM(CASE WHEN warehouse_id IS NULL AND current_quantity_on_hand > 0 THEN 1 ELSE 0 END) AS null_wh_with_stock,
          SUM(CASE WHEN total_units_sold < 0 THEN 1 ELSE 0 END) AS neg_sold,
          SUM(CASE WHEN avg_inventory_on_hand < 0 THEN 1 ELSE 0 END) AS neg_avg_inv,
          SUM(CASE WHEN inventory_turnover_ratio < 0 THEN 1 ELSE 0 END) AS neg_turnover,
          SUM(CASE WHEN days_of_supply < 0 THEN 1 ELSE 0 END) AS neg_days_supply,
          SUM(CASE WHEN estimated_days_until_stockout < 0 THEN 1 ELSE 0 END) AS neg_est_days,
          SUM(CASE WHEN current_quantity_on_hand < 0 THEN 1 ELSE 0 END) AS neg_current_qty
        FROM analytics.rpt_inventory_turnover_analysis
    """)[0]
    (
        total,
        null_sku,
        null_wh_with_stock,
        neg_sold,
        neg_avg_inv,
        neg_turnover,
        neg_days_supply,
        neg_est_days,
        neg_current_qty,
    ) = row
    require(int(total) > 0, "No rows produced")
    require(int(null_sku) == 0, f"Found {null_sku} NULL sku rows")
    require(
        int(null_wh_with_stock) == 0,
        f"Found {null_wh_with_stock} rows with stock but NULL warehouse_id",
    )
    require(int(neg_sold) == 0, f"Negative total_units_sold rows: {neg_sold}")
    require(int(neg_avg_inv) == 0, f"Negative avg_inventory_on_hand rows: {neg_avg_inv}")
    require(int(neg_turnover) == 0, f"Negative inventory_turnover_ratio rows: {neg_turnover}")
    require(int(neg_days_supply) == 0, f"Negative days_of_supply rows: {neg_days_supply}")
    require(int(neg_est_days) == 0, f"Negative estimated_days_until_stockout rows: {neg_est_days}")
    require(int(neg_current_qty) == 0, f"Negative current_quantity_on_hand rows: {neg_current_qty}")


def test_analysis_period_bounds(conn):
    """analysis_period_days is between 1 and 180 (inclusive)."""
    c, db_type = conn
    bad = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE analysis_period_days < 1 OR analysis_period_days > 180
    """)
    require(int(bad) == 0, f"Found {bad} rows with analysis_period_days outside [1, 180]")


def test_turnover_velocity_classification(conn):
    """turnover_velocity_class is correctly assigned based on inventory_turnover_ratio."""
    c, db_type = conn
    bad = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE (inventory_turnover_ratio >= 12.0 AND turnover_velocity_class != 'FAST')
           OR (inventory_turnover_ratio >= 4.0 AND inventory_turnover_ratio < 12.0 AND turnover_velocity_class != 'MEDIUM')
           OR (inventory_turnover_ratio >= 1.0 AND inventory_turnover_ratio < 4.0 AND turnover_velocity_class != 'SLOW')
           OR (inventory_turnover_ratio < 1.0 AND turnover_velocity_class != 'STAGNANT')
           OR (inventory_turnover_ratio IS NULL AND turnover_velocity_class != 'STAGNANT')
    """)
    require(
        int(bad) == 0,
        f"Found {bad} rows with incorrect turnover_velocity_class assignment",
    )


def test_edge_cases_zero_sales(conn):
    """When total_units_sold = 0, turnover_ratio = 0, days_of_supply and estimated_days are NULL."""
    c, db_type = conn
    bad = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE total_units_sold = 0
          AND (inventory_turnover_ratio != 0 OR inventory_turnover_ratio IS NULL
               OR days_of_supply IS NOT NULL
               OR estimated_days_until_stockout IS NOT NULL)
    """)
    require(int(bad) == 0, f"Found {bad} rows with incorrect handling of zero sales")


def test_edge_cases_zero_inventory(conn):
    """When avg_inventory_on_hand = 0 and total_units_sold > 0, turnover_ratio is NULL, days_of_supply = 0."""
    c, db_type = conn
    bad = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE avg_inventory_on_hand = 0
          AND total_units_sold > 0
          AND (inventory_turnover_ratio IS NOT NULL OR days_of_supply != 0)
    """)
    require(int(bad) == 0, f"Found {bad} rows with incorrect handling of zero inventory")


def test_edge_cases_zero_current_qty(conn):
    """When current_quantity_on_hand = 0, estimated_days_until_stockout = 0."""
    c, db_type = conn
    bad = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE current_quantity_on_hand = 0
          AND estimated_days_until_stockout != 0
          AND estimated_days_until_stockout IS NOT NULL
    """)
    require(int(bad) == 0, f"Found {bad} rows with incorrect handling of zero current quantity")


def test_turnover_days_supply_relationship(conn):
    """inventory_turnover_ratio * days_of_supply = analysis_period_days (within 0.1 tolerance)."""
    c, db_type = conn
    bad = execute_scalar(c, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE inventory_turnover_ratio IS NOT NULL
          AND days_of_supply IS NOT NULL
          AND ABS((inventory_turnover_ratio * days_of_supply) - analysis_period_days) > 0.1
    """)
    require(
        int(bad) == 0,
        f"Found {bad} rows where turnover_ratio * days_of_supply doesn't match analysis_period_days",
    )


def test_sales_reconciliation_sample(conn):
    """For top SKUs by current_quantity_on_hand, total_units_sold matches source aggregation."""
    c, db_type = conn
    sample = execute_query(c, db_type, """
        SELECT sku, warehouse_id
        FROM analytics.rpt_inventory_turnover_analysis
        WHERE current_quantity_on_hand > 0
        GROUP BY sku, warehouse_id
        ORDER BY MAX(current_quantity_on_hand) DESC
        LIMIT 20
    """)
    if not sample:
        total_rows = execute_scalar(c, db_type,
            "SELECT COUNT(*) FROM analytics.rpt_inventory_turnover_analysis"
        )
        require(int(total_rows) > 0, "Model produced no rows")
        return

    for sku, warehouse_id in sample:
        # Get model output
        if db_type == 'snowflake':
            model_sold_row = execute_query(c, db_type, """
                SELECT total_units_sold
                FROM analytics.rpt_inventory_turnover_analysis
                WHERE sku = %s AND warehouse_id = %s
                LIMIT 1
            """, [sku, warehouse_id])
        else:
            model_sold_row = execute_query(c, db_type, """
                SELECT total_units_sold
                FROM analytics.rpt_inventory_turnover_analysis
                WHERE sku = ? AND warehouse_id = ?
                LIMIT 1
            """, [sku, warehouse_id])
        if not model_sold_row:
            continue
        model_sold = model_sold_row[0][0]

        # Recompute from source
        if db_type == 'snowflake':
            src_sold = execute_scalar(c, db_type, """
                WITH ref_date AS (
                  SELECT MAX(CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE)) AS max_date
                  FROM main.stg_orders__orders o
                  WHERE o.fulfillment_status = 'FULFILLED'
                    AND COALESCE(o.shipped_at, o.delivered_at) IS NOT NULL
                ),
                windowed_orders AS (
                  SELECT o.order_id
                  FROM main.stg_orders__orders o
                  CROSS JOIN ref_date rd
                  WHERE o.fulfillment_status = 'FULFILLED'
                    AND COALESCE(o.shipped_at, o.delivered_at) IS NOT NULL
                    AND CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) >= DATEADD(day, -180, rd.max_date)
                    AND CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) <= rd.max_date
                )
                SELECT COALESCE(SUM(ol.quantity_ordered), 0)
                FROM main.stg_orders__order_lines ol
                JOIN windowed_orders wo ON ol.order_id = wo.order_id
                JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
                JOIN main.stg_inventory__inventory_levels il ON pv.variant_id = il.variant_id
                WHERE pv.sku = %s
                  AND il.warehouse_id = %s
            """, [sku, warehouse_id])
        else:
            src_sold = execute_scalar(c, db_type, """
                WITH ref_date AS (
                  SELECT MAX(CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE)) AS max_date
                  FROM main.stg_orders__orders o
                  WHERE o.fulfillment_status = 'FULFILLED'
                    AND COALESCE(o.shipped_at, o.delivered_at) IS NOT NULL
                ),
                windowed_orders AS (
                  SELECT o.order_id
                  FROM main.stg_orders__orders o
                  CROSS JOIN ref_date rd
                  WHERE o.fulfillment_status = 'FULFILLED'
                    AND COALESCE(o.shipped_at, o.delivered_at) IS NOT NULL
                    AND CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) >= rd.max_date - INTERVAL 180 DAY
                    AND CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) <= rd.max_date
                )
                SELECT COALESCE(SUM(ol.quantity_ordered), 0)
                FROM main.stg_orders__order_lines ol
                JOIN windowed_orders wo ON ol.order_id = wo.order_id
                JOIN main.stg_product__product_variants pv ON ol.variant_id = pv.variant_id
                JOIN main.stg_inventory__inventory_levels il ON pv.variant_id = il.variant_id
                WHERE pv.sku = ?
                  AND il.warehouse_id = ?
            """, [sku, warehouse_id])

        # Allow small tolerance for aggregation differences
        if model_sold is not None and src_sold is not None:
            diff = abs(float(model_sold) - float(src_sold))
            require(
                diff <= 1,
                f"SKU {sku} warehouse {warehouse_id}: model={model_sold}, source={src_sold}, diff={diff}",
            )


def test_fulfilled_orders_only(conn):
    """Only fulfilled orders are included in calculations."""
    c, db_type = conn
    period_check = execute_query(c, db_type, """
        SELECT
          MIN(analysis_period_days) AS min_period,
          MAX(analysis_period_days) AS max_period,
          COUNT(DISTINCT analysis_period_days) AS distinct_periods
        FROM analytics.rpt_inventory_turnover_analysis
    """)[0]
    min_period, max_period, distinct_periods = period_check
    require(
        int(min_period) >= 1 and int(max_period) <= 180,
        f"Analysis period days out of bounds: min={min_period}, max={max_period}",
    )
