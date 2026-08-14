"""
Test verifier for dbt-multi-warehouse-stock-rebalance task.
"""
import subprocess
import os
import math
import json
from pathlib import Path


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
        conn = duckdb.connect("/app/database/retail.duckdb", read_only=True)
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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    model_path = f"{get_dbt_project_dir()}/models/marts/inventory/rpt_warehouse_rebalancing.sql"
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    # First run dbt deps to install packages
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    result = run_cmd("dbt run -s rpt_warehouse_rebalancing")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                total_quantity_on_hand, avg_unit_cost, total_inventory_value,
                avg_daily_sales_velocity, days_of_stock_remaining,
                stock_concentration_ratio, stock_imbalance_score,
                utilization_rate, rebalancing_priority
            FROM main.rpt_warehouse_rebalancing
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                try:
                    if val is not None and (math.isinf(float(val)) or math.isnan(float(val))):
                        inf_nan_count += 1
                except (TypeError, ValueError, OverflowError):
                    pass

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    conn, db_type = get_db_connection()
    try:
        output_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_warehouse_rebalancing
        """)

        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT il.variant_id)
            FROM main.stg_inventory__inventory_levels il
            INNER JOIN main.stg_inventory__warehouses w ON il.warehouse_id = w.warehouse_id
            WHERE w.IS_ACTIVE = true
              AND il.QUANTITY_ON_HAND > 0
              AND il.variant_id IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns ============

def component_4_required_columns():
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'variant_id', 'total_warehouses_stocked', 'total_quantity_on_hand',
            'total_quantity_available', 'total_quantity_reserved', 'avg_unit_cost',
            'total_inventory_value', 'max_warehouse_stock', 'min_warehouse_stock',
            'total_units_sold_90d', 'total_orders_90d', 'avg_daily_sales_velocity',
            'days_of_stock_remaining', 'stock_concentration_ratio', 'stock_imbalance_score',
            'utilization_rate', 'rebalancing_priority', 'rebalancing_action'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.rpt_warehouse_rebalancing LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.rpt_warehouse_rebalancing LIMIT 1").description
            actual_columns = [col[0].lower() for col in result]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Action Values ============

def component_5_valid_action_values():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT rebalancing_action FROM main.rpt_warehouse_rebalancing
        """)

        valid_actions = {'urgent_rebalance', 'high_priority', 'rebalance_recommended',
                        'monitor', 'well_distributed'}
        actual_actions = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_actions - valid_actions - {None}
        require(len(invalid) == 0, f"Invalid action values: {invalid}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Uses Window Function ============

def component_6_uses_window_function():
    sql = read_model_file().lower()
    has_window = 'percent_rank()' in sql or 'ntile(' in sql
    require(has_window, "Must use PERCENT_RANK() or NTILE() for percentile-based classification")
    return 1.0


# ============ COMPONENT 7: Action Distribution ============

def component_7_action_distribution():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT rebalancing_action, COUNT(*) as cnt
            FROM main.rpt_warehouse_rebalancing
            GROUP BY rebalancing_action
        """)

        action_counts = {row[0].lower(): row[1] for row in result}
        require(len(action_counts) >= 2, f"Only {len(action_counts)} distinct actions")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: Priority Formula Validation ============

def component_8_priority_formula():
    """Validate exact priority formula: 35% imbalance + 25% concentration + conditionals"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT
                variant_id,
                stock_imbalance_score,
                stock_concentration_ratio,
                days_of_stock_remaining,
                total_warehouses_stocked,
                rebalancing_priority
            FROM main.rpt_warehouse_rebalancing
            WHERE rebalancing_priority IS NOT NULL
            LIMIT 50
        """)

        errors = []
        for vid, imb, conc, days, wh_count, actual_priority in results:
            imb = imb or 0
            conc = conc or 0
            days = days if days is not None else 999
            wh_count = wh_count or 0

            # Expected formula: imbalance*35 + concentration*25 + (days<14?20:0) + (wh<3?20:0)
            expected = (imb * 35 + conc * 25 +
                       (20 if days < 14 else 0) +
                       (20 if wh_count < 3 else 0))
            expected = min(100, max(0, expected))

            if abs(actual_priority - expected) > 1.0:
                errors.append(f"variant {vid}: priority={actual_priority:.1f}, expected={expected:.1f}")

        require(len(errors) == 0, f"Priority formula incorrect:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_valid_action_values": 1.0,
    "component_6_uses_window_function": 1.0,
    "component_7_action_distribution": 1.0,
    "component_8_priority_formula": 1.0,
}


def test_solution():
    scores = {}

    for component_name in WEIGHTS:
        try:
            component_func = globals()[component_name]
            scores[component_name] = component_func()
            print(f"PASS: {component_name}")
        except Exception as e:
            scores[component_name] = 0.0
            print(f"FAIL: {component_name}: {e}")

    all_passed = all(scores.get(key, 0) == 1.0 for key in WEIGHTS)
    final_score = 1.0 if all_passed else 0.0

    Path("/logs/verifier").mkdir(parents=True, exist_ok=True)
    Path("/logs/verifier/reward.txt").write_text(str(final_score))
    # Harbor requires reward.json to be a single-key dict[str, float|int]
    # (harbor.utils.pass_at_k rejects len(rewards) != 1; VerifierResult.rewards
    # is dict[str, float|int]). Emit the overall score as {"reward": ...},
    # matching reward.txt; per-component pass/fail is in the verifier stdout above.
    Path("/logs/verifier/reward.json").write_text(json.dumps({"reward": final_score}))

    print(f"\nFinal Score: {final_score}")
    assert final_score == 1.0, f"Score: {final_score}"
