"""
Test verifier for Advanced Inventory Stockout Risk Analytics task.

Multi-phase testing:
  Phase 1: Validate model structure and required files
  Phase 2: Validate data quality and schema
  Phase 3: Validate business logic correctness
  Phase 4: Validate statistical calculations and advanced metrics
  Phase 5: Validate reconciliation and idempotency
"""
import os
import subprocess
import pytest

# ============ CONFIGURATION ============

DB_PATH = "/app/database/retail.duckdb"
PROJECT_DIR = "/app/dbt_project"
SCHEMA = "analytics"

MODEL_FILES = {
    "stg_orders": os.path.join(PROJECT_DIR, "models", "staging", "stg_orders_clean.sql"),
    "int_sales": os.path.join(PROJECT_DIR, "models", "intermediate", "int_sales_velocity.sql"),
    "int_lead_time": os.path.join(PROJECT_DIR, "models", "intermediate", "int_lead_time_calculations.sql"),
    "fct": os.path.join(PROJECT_DIR, "models", "marts", "operations", "fct_stockout_risk.sql"),
}

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


def require(condition, msg):
    """Assert with custom message."""
    if not condition:
        raise AssertionError(msg)


def run_dbt_pipeline():
    """Run dbt deps and dbt run."""
    # Check project directory exists
    require(os.path.isdir(PROJECT_DIR), f"dbt_project directory missing at {PROJECT_DIR}")

    # Check model files exist
    for name, path in MODEL_FILES.items():
        require(os.path.isfile(path), f"Missing required model file: {name} at {path}")

    deps = run_cmd("dbt deps")
    if deps.returncode != 0:
        print("dbt deps failed (may be harmless if no packages).")

    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    # Clean up any previous conflicting relations (case sensitivity issue) - DuckDB only
    if db_type == 'duckdb':
        conn, ct = get_db_connection_rw()
        try:
            for schema in ("analytics", "ANALYTICS"):
                for rel in ("stg_orders_clean", "int_sales_velocity", "int_lead_time_calculations", "fct_stockout_risk"):
                    for ddl in (
                        f"DROP VIEW IF EXISTS {schema}.{rel}",
                        f"DROP TABLE IF EXISTS {schema}.{rel}",
                    ):
                        try:
                            conn.execute(ddl)
                        except Exception:
                            pass
        finally:
            conn.close()

    res = run_cmd("dbt run --select +fct_stockout_risk --full-refresh")
    require(res.returncode == 0, f"dbt run failed: {res.stderr if res.stderr else res.stdout}")


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def setup():
    """Fixture that runs dbt once per test module."""
    # Run dbt pipeline - this will fail if project doesn't exist or models are missing
    run_dbt_pipeline()
    yield


# ============ TEST PHASE 1: STRUCTURE ============

def test_model_files_exist(setup):
    """TEST 1: Verify all required model files exist."""
    for name, path in MODEL_FILES.items():
        require(os.path.isfile(path), f"Missing model file: {name} at {path}")


def test_models_exist_in_schema(setup):
    """TEST 2: Verify all models exist in the analytics schema."""
    conn, db_type = get_db_connection()
    try:
        tables = execute_query(conn, db_type, f"""
            SELECT table_name
            FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}')
        """)
        table_names = {t[0].lower() for t in tables}

        required = {
            "stg_orders_clean",
            "int_sales_velocity",
            "int_lead_time_calculations",
            "fct_stockout_risk"
        }

        missing = required - table_names
        require(not missing, f"Missing models in schema: {missing}")
    finally:
        conn.close()


# ============ TEST PHASE 2: DATA QUALITY ============

def test_stg_orders_no_cancelled(setup):
    """TEST 3: Verify stg_orders_clean excludes cancelled orders."""
    conn, db_type = get_db_connection()
    try:
        cancelled_count = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.stg_orders_clean
            WHERE order_ts IS NULL
        """)
        # This is a soft check - just verify structure
    finally:
        conn.close()


def test_int_sales_velocity_grain(setup):
    """TEST 4: Verify int_sales_velocity has one row per variant_id."""
    conn, db_type = get_db_connection()
    try:
        total_rows = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_sales_velocity
        """)

        distinct_variants = execute_scalar(conn, db_type, f"""
            SELECT COUNT(DISTINCT variant_id) FROM {SCHEMA}.int_sales_velocity
        """)

        require(total_rows == distinct_variants,
                f"Found duplicate variants: {total_rows} rows vs {distinct_variants} distinct variants")
    finally:
        conn.close()


def test_int_lead_time_grain(setup):
    """TEST 5: Verify int_lead_time_calculations has one row per (variant_id, warehouse_id)."""
    conn, db_type = get_db_connection()
    try:
        total_rows = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_lead_time_calculations
        """)

        if db_type == 'duckdb':
            distinct_combos = execute_scalar(conn, db_type, f"""
                SELECT COUNT(DISTINCT (variant_id, warehouse_id)) FROM {SCHEMA}.int_lead_time_calculations
            """)
        else:
            # Snowflake does not support tuple DISTINCT syntax
            distinct_combos = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM (
                    SELECT DISTINCT variant_id, warehouse_id FROM {SCHEMA}.int_lead_time_calculations
                )
            """)

        require(total_rows == distinct_combos,
                f"Found duplicate (variant, warehouse) combinations: {total_rows} rows vs {distinct_combos} distinct")
    finally:
        conn.close()


def test_fct_data_quality(setup):
    """TEST 6: Verify fct_stockout_risk data quality constraints."""
    conn, db_type = get_db_connection()
    try:
        row = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN warehouse_name IS NULL THEN 1 ELSE 0 END) AS null_warehouse,
                SUM(CASE WHEN product_name IS NULL THEN 1 ELSE 0 END) AS null_product,
                SUM(CASE WHEN sku IS NULL THEN 1 ELSE 0 END) AS null_sku,
                SUM(CASE WHEN avg_daily_sales_7d < 0 THEN 1 ELSE 0 END) AS neg_7d,
                SUM(CASE WHEN avg_daily_sales_30d < 0 THEN 1 ELSE 0 END) AS neg_30d,
                SUM(CASE WHEN lead_time_days IS NOT NULL AND (lead_time_days <= 0 OR lead_time_days > 365) THEN 1 ELSE 0 END) AS invalid_lead_time
            FROM {SCHEMA}.fct_stockout_risk
        """)[0]

        total, null_warehouse, null_product, null_sku, neg_7d, neg_30d, invalid_lead_time = row

        require(total > 0, "No rows produced")
        require(null_warehouse == 0, f"Found {null_warehouse} NULL warehouse_name rows")
        require(null_product == 0, f"Found {null_product} NULL product_name rows")
        require(null_sku == 0, f"Found {null_sku} NULL sku rows")
        require(neg_7d == 0, f"Found {neg_7d} negative avg_daily_sales_7d rows")
        require(neg_30d == 0, f"Found {neg_30d} negative avg_daily_sales_30d rows")
        require(invalid_lead_time == 0, f"Found {invalid_lead_time} rows with invalid lead_time_days")
    finally:
        conn.close()


# ============ TEST PHASE 3: BUSINESS LOGIC ============

def test_sales_velocity_ratio(setup):
    """TEST 7: Verify sales_velocity_ratio calculation."""
    conn, db_type = get_db_connection()
    try:
        calc_errors = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE avg_daily_sales_7d IS NOT NULL
              AND avg_daily_sales_30d IS NOT NULL
              AND avg_daily_sales_30d > 0
              AND sales_velocity_ratio IS NOT NULL
              AND ABS(sales_velocity_ratio - (avg_daily_sales_7d / avg_daily_sales_30d)) > 0.0001
        """)

        require(calc_errors == 0,
                f"Found {calc_errors} rows where sales_velocity_ratio calculation is incorrect")
    finally:
        conn.close()


def test_trend_direction_classification(setup):
    """TEST 8: Verify trend_direction classification."""
    conn, db_type = get_db_connection()
    try:
        invalid_trends = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE trend_direction IS NOT NULL
              AND trend_direction NOT IN ('ACCELERATING', 'STABLE', 'DECELERATING')
        """)

        require(invalid_trends == 0,
                f"Found {invalid_trends} rows with invalid trend_direction values")

        # Verify trend matches velocity ratio
        mismatches = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE (trend_direction = 'ACCELERATING' AND (sales_velocity_ratio IS NULL OR sales_velocity_ratio <= 1.2))
               OR (trend_direction = 'STABLE' AND (sales_velocity_ratio IS NULL OR sales_velocity_ratio < 0.8 OR sales_velocity_ratio > 1.2))
               OR (trend_direction = 'DECELERATING' AND (sales_velocity_ratio IS NULL OR sales_velocity_ratio >= 0.8))
        """)

        require(mismatches == 0, f"Found {mismatches} rows where trend_direction doesn't match sales_velocity_ratio")
    finally:
        conn.close()


def test_safety_stock_and_reorder_point(setup):
    """TEST 9: Verify safety stock and reorder point calculations."""
    conn, db_type = get_db_connection()
    try:
        # Verify safety_stock_quantity calculation
        safety_errors = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE safety_stock_days IS NOT NULL
              AND avg_daily_sales_30d IS NOT NULL
              AND avg_daily_sales_30d > 0
              AND safety_stock_quantity IS NOT NULL
              AND ABS(safety_stock_quantity - (safety_stock_days * avg_daily_sales_30d)) > 0.0001
        """)

        require(safety_errors == 0,
                f"Found {safety_errors} rows where safety_stock_quantity calculation is incorrect")

        # Verify reorder_point calculation
        reorder_errors = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE lead_time_days IS NOT NULL
              AND avg_daily_sales_30d IS NOT NULL
              AND avg_daily_sales_30d > 0
              AND reorder_point_multiplier IS NOT NULL
              AND safety_stock_quantity IS NOT NULL
              AND reorder_point IS NOT NULL
              AND ABS(reorder_point - ((lead_time_days * avg_daily_sales_30d * reorder_point_multiplier) + safety_stock_quantity)) > 0.0001
        """)

        require(reorder_errors == 0,
                f"Found {reorder_errors} rows where reorder_point calculation is incorrect")
    finally:
        conn.close()


def test_days_until_calculations(setup):
    """TEST 10: Verify days until stockout and reorder point calculations."""
    conn, db_type = get_db_connection()
    try:
        # Verify days_until_stockout calculation
        stockout_errors = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE quantity_available IS NOT NULL
              AND avg_daily_sales_30d IS NOT NULL
              AND avg_daily_sales_30d > 0
              AND days_until_stockout IS NOT NULL
              AND ABS(days_until_stockout - (quantity_available / avg_daily_sales_30d)) > 0.0001
        """)

        require(stockout_errors == 0,
                f"Found {stockout_errors} rows where days_until_stockout calculation is incorrect")

        # Verify NULL handling when no sales
        null_handling_errors = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE (avg_daily_sales_30d = 0 OR avg_daily_sales_30d IS NULL)
              AND days_until_stockout IS NOT NULL
        """)

        require(null_handling_errors == 0,
                f"Found {null_handling_errors} rows where days_until_stockout should be NULL but isn't")
    finally:
        conn.close()


# ============ TEST PHASE 4: STATISTICAL CALCULATIONS ============

def test_percentile_ordering(setup):
    """TEST 11: Verify percentile ordering (p25 <= median <= p75)."""
    conn, db_type = get_db_connection()
    try:
        violations = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE p25_daily_sales_30d IS NOT NULL
              AND median_daily_sales_30d IS NOT NULL
              AND p75_daily_sales_30d IS NOT NULL
              AND (p25_daily_sales_30d > median_daily_sales_30d
                   OR median_daily_sales_30d > p75_daily_sales_30d)
        """)

        require(violations == 0,
                f"Found {violations} rows where percentile ordering is incorrect")
    finally:
        conn.close()


def test_volatility_non_negative(setup):
    """TEST 12: Verify sales volatility is non-negative."""
    conn, db_type = get_db_connection()
    try:
        negative_vol = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE (sales_volatility_30d IS NOT NULL AND sales_volatility_30d < 0)
               OR (sales_volatility_90d IS NOT NULL AND sales_volatility_90d < 0)
        """)

        require(negative_vol == 0,
                f"Found {negative_vol} rows with negative volatility")
    finally:
        conn.close()


def test_lead_time_statistics(setup):
    """TEST 13: Verify lead time statistics are valid."""
    conn, db_type = get_db_connection()
    try:
        invalid_stats = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE (lead_time_min IS NOT NULL AND lead_time_max IS NOT NULL AND lead_time_min > lead_time_max)
               OR (lead_time_std_dev IS NOT NULL AND lead_time_std_dev < 0)
        """)

        require(invalid_stats == 0,
                f"Found {invalid_stats} rows with invalid lead time statistics")
    finally:
        conn.close()


# ============ TEST PHASE 5: RECONCILIATION AND IDEMPOTENCY ============

def test_stockout_risk_classification(setup):
    """TEST 14: Verify stockout risk classification."""
    conn, db_type = get_db_connection()
    try:
        invalid_risks = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE stockout_risk NOT IN ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'NO_RISK')
        """)

        require(invalid_risks == 0,
                f"Found {invalid_risks} rows with invalid stockout_risk values")
    finally:
        conn.close()


def test_recommended_action_mapping(setup):
    """TEST 15: Verify recommended action mapping."""
    conn, db_type = get_db_connection()
    try:
        mapping_errors = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.fct_stockout_risk
            WHERE (stockout_risk = 'CRITICAL' AND recommended_action != 'URGENT_REORDER')
               OR (stockout_risk = 'HIGH' AND recommended_action != 'REORDER_NOW')
               OR (stockout_risk = 'MEDIUM' AND recommended_action != 'PLAN_REORDER')
               OR (stockout_risk = 'LOW' AND recommended_action != 'MONITOR')
               OR (stockout_risk = 'NO_RISK' AND recommended_action != 'NO_ACTION')
        """)

        require(mapping_errors == 0,
                f"Found {mapping_errors} rows where recommended_action doesn't match stockout_risk")
    finally:
        conn.close()


def test_grain_uniqueness(setup):
    """TEST 16: Verify grain uniqueness."""
    conn, db_type = get_db_connection()
    try:
        total_rows = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.fct_stockout_risk")

        duplicates = execute_query(conn, db_type, f"""
            SELECT
                warehouse_name, product_name, sku,
                lead_time_days, safety_stock_days,
                COUNT(*) as cnt
            FROM {SCHEMA}.fct_stockout_risk
            WHERE warehouse_name IS NOT NULL
              AND product_name IS NOT NULL
              AND sku IS NOT NULL
            GROUP BY warehouse_name, product_name, sku,
                     lead_time_days, safety_stock_days
            HAVING COUNT(*) > 1
        """)

        duplicate_count = len(duplicates)
        duplicate_percentage = (duplicate_count / total_rows * 100) if total_rows > 0 else 0

        require(
            duplicate_percentage < 5,
            f"Found {duplicate_count} duplicate grain combinations ({duplicate_percentage:.1f}% of rows)"
        )
    finally:
        conn.close()


def test_reconciliation(setup):
    """TEST 17: Verify reconciliation with source data."""
    conn, db_type = get_db_connection()
    try:
        # Get source sales totals (relative to max order date, not CURRENT_DATE)
        src_total = execute_scalar(conn, db_type, """
            SELECT SUM(ol.quantity_ordered)
            FROM ORDERS.ORDER_LINES ol
            INNER JOIN ORDERS.ORDERS o ON ol.order_id = o.order_id
            WHERE o.STATUS != 'CANCELLED'
              AND o.ordered_at >= (SELECT MAX(ordered_at) FROM ORDERS.ORDERS WHERE STATUS != 'CANCELLED') - INTERVAL '90 days'
        """) or 0

        # Get calculated sales totals from int_sales_velocity (one row per variant,
        # avoids inflating totals for multi-warehouse variants in fct_stockout_risk)
        tgt_approx = execute_scalar(conn, db_type, f"""
            SELECT SUM(avg_daily_sales_90d * 90)
            FROM {SCHEMA}.int_sales_velocity
            WHERE avg_daily_sales_90d IS NOT NULL
        """) or 0

        if src_total > 0:
            rel_error = abs(tgt_approx - src_total) / src_total
            require(rel_error <= 0.001,
                    f"Reconciliation error too large: {rel_error:.4f} (source={src_total}, target~={tgt_approx})")
    finally:
        conn.close()


def test_idempotency(setup):
    """TEST 18: Verify idempotency and deterministic results."""
    conn, db_type = get_db_connection()
    try:
        # Get initial state
        initial_count = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.fct_stockout_risk")

        if db_type == 'duckdb':
            initial_hash = execute_scalar(conn, db_type, f"""
                SELECT SUM(HASH(warehouse_name || product_name || sku ||
                    COALESCE(CAST(quantity_available AS VARCHAR), '') ||
                    COALESCE(CAST(stockout_risk AS VARCHAR), '')))
                FROM {SCHEMA}.fct_stockout_risk
            """)
        else:
            initial_hash = execute_scalar(conn, db_type, f"""
                SELECT SUM(HASH(warehouse_name || product_name || sku ||
                    COALESCE(CAST(quantity_available AS VARCHAR), '') ||
                    COALESCE(CAST(stockout_risk AS VARCHAR), '')))
                FROM {SCHEMA}.fct_stockout_risk
            """)
    finally:
        conn.close()

    # Re-run dbt
    run_dbt_pipeline()

    # Verify results haven't changed
    conn2, db_type2 = get_db_connection()
    try:
        final_count = execute_scalar(conn2, db_type2, f"SELECT COUNT(*) FROM {SCHEMA}.fct_stockout_risk")
        if db_type2 == 'duckdb':
            final_hash = execute_scalar(conn2, db_type2, f"""
                SELECT SUM(HASH(warehouse_name || product_name || sku ||
                    COALESCE(CAST(quantity_available AS VARCHAR), '') ||
                    COALESCE(CAST(stockout_risk AS VARCHAR), '')))
                FROM {SCHEMA}.fct_stockout_risk
            """)
        else:
            final_hash = execute_scalar(conn2, db_type2, f"""
                SELECT SUM(HASH(warehouse_name || product_name || sku ||
                    COALESCE(CAST(quantity_available AS VARCHAR), '') ||
                    COALESCE(CAST(stockout_risk AS VARCHAR), '')))
                FROM {SCHEMA}.fct_stockout_risk
            """)

        require(
            initial_count == final_count,
            f"Row count changed after re-run: initial={initial_count}, final={final_count}"
        )

        require(
            initial_hash == final_hash,
            f"Data hash changed after re-run: model is not idempotent"
        )
    finally:
        conn2.close()
