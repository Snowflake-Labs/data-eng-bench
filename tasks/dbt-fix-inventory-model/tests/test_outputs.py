"""
Test verifier for dbt-fix-inventory-model.

Components:
1. Model compiles and runs successfully
2. No inf/nan values in numeric columns
3. Row count matches source (catches NULL/WHERE bugs)
4. inventory_health_tier column exists
5. velocity_score column exists
6. Valid tier values only
7. Uses PERCENT_RANK window function (required for top 10%)
8. Tier distribution is reasonable
9. Critical tier logic: top 10% turnover AND days_of_supply < 7 AND units_sold > 0
10. Healthy tier logic: top 50% turnover AND stockout_rate < 5% AND days_of_supply 14-90
11. velocity_score is in valid range (0-100)
12. velocity_score formula verification (spot check)
"""
import subprocess
import math
import json
import os
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
    """Get the dbt project directory based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


def run_cmd(cmd, cwd=None):
    """Run a shell command and return the result."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    """Read the model SQL file."""
    dbt_dir = get_dbt_project_dir()
    model_path = os.path.join(dbt_dir, "models/marts/inventory/rpt_product_inventory_metrics.sql")
    with open(model_path, "r") as f:
        return f.read()


def get_table_ref():
    """Get the table reference based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        schema = 'main'
        return f"{schema}.rpt_product_inventory_metrics"
    else:
        return "main.rpt_product_inventory_metrics"


def get_staging_table_ref():
    """Get the staging table reference based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        schema = 'main'
        return f"{schema}.stg_inventory__inventory_levels"
    else:
        return "main.stg_inventory__inventory_levels"


def require(condition, message):
    """Assert with descriptive message."""
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    """Model should compile and run without error."""
    result = run_cmd("dbt run -s rpt_product_inventory_metrics")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """No infinity or NaN values in numeric columns."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                turnover_ratio,
                inventory_value_per_unit_sold,
                stockout_rate,
                days_of_supply,
                total_inventory_value,
                avg_unit_cost,
                cogs_365d
            FROM {table}
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None:
                    try:
                        if math.isinf(float(val)) or math.isnan(float(val)):
                            inf_nan_count += 1
                    except (TypeError, ValueError):
                        pass

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values in numeric columns")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    """All products must be included (catches WHERE clause bug)."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    staging_table = get_staging_table_ref()
    try:
        output_count = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {table}
        """)

        source_count = execute_scalar(conn, db_type, f"""
            SELECT COUNT(DISTINCT variant_id)
            FROM {staging_table}
            WHERE variant_id IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output {output_count} vs source {source_count}. "
                f"Check if WHERE clause is filtering out valid products.")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: inventory_health_tier Column Exists ============

def component_4_tier_column_exists():
    """inventory_health_tier column must exist."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT inventory_health_tier
            FROM {table}
            LIMIT 1
        """)
        require(len(result) > 0 and result[0] is not None, "inventory_health_tier column missing or table is empty")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: velocity_score Column Exists ============

def component_5_velocity_score_exists():
    """velocity_score column must exist."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT velocity_score
            FROM {table}
            LIMIT 1
        """)
        require(len(result) > 0 and result[0] is not None, "velocity_score column missing or table is empty")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Valid Tier Values ============

def component_6_valid_tier_values():
    """inventory_health_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT inventory_health_tier
            FROM {table}
            WHERE inventory_health_tier IS NOT NULL
        """)

        valid_values = {'critical', 'at_risk', 'healthy', 'overstock'}
        actual = {row[0].lower() if row[0] else None for row in result}
        actual.discard(None)

        invalid = actual - valid_values
        require(len(invalid) == 0, f"Invalid tier values found: {invalid}. Expected only: {valid_values}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 7: Uses PERCENT_RANK ============

def component_7_uses_percent_rank():
    """Must use PERCENT_RANK() for top 10% calculation (required by spec)."""
    sql = read_model_file().lower()

    has_percent_rank = 'percent_rank()' in sql or 'percent_rank ()' in sql

    require(has_percent_rank,
            "Must use PERCENT_RANK() window function for tier calculation. "
            "The 'critical' tier requires identifying top 10% by turnover ratio.")
    return 1.0


# ============ COMPONENT 8: Tier Distribution ============

def component_8_distribution():
    """Tiers must have reasonable distribution (not all same)."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT inventory_health_tier, COUNT(*) as cnt
            FROM {table}
            WHERE inventory_health_tier IS NOT NULL
            GROUP BY inventory_health_tier
        """)

        tier_counts = {row[0]: row[1] for row in result if row[0]}

        require(len(tier_counts) >= 2,
                f"Only {len(tier_counts)} tier(s) found: {list(tier_counts.keys())}. "
                f"Tier logic may be wrong - distribution should be more varied.")

        total = sum(tier_counts.values())
        for tier, count in tier_counts.items():
            pct = count / total
            require(pct < 0.85,
                    f"Tier '{tier}' has {pct*100:.1f}% of all products. "
                    f"Distribution is too skewed - check tier logic.")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 9: Critical Tier Logic ============

def component_9_critical_tier_logic():
    """Critical tier must be: top 10% turnover AND days_of_supply < 7 AND units_sold > 0."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        # Get critical tier products
        critical_products = execute_query(conn, db_type, f"""
            SELECT product_id, turnover_ratio, days_of_supply, units_sold_365d
            FROM {table}
            WHERE LOWER(inventory_health_tier) = 'critical'
        """)

        if len(critical_products) == 0:
            return 1.0

        # Get 90th percentile threshold for turnover
        p90_turnover = execute_scalar(conn, db_type, f"""
            SELECT PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY turnover_ratio)
            FROM {table}
            WHERE turnover_ratio IS NOT NULL
        """)

        # All critical products must meet ALL conditions
        for product_id, turnover, days_supply, units_sold in critical_products:
            # Must be top 10% by turnover (>= 90th percentile)
            if turnover is not None and p90_turnover is not None:
                require(float(turnover) >= float(p90_turnover) * 0.95,  # 5% tolerance
                        f"Critical product {product_id} has turnover {turnover} "
                        f"below 90th percentile threshold {p90_turnover}")

            # Must have days_of_supply < 7
            if days_supply is not None:
                require(float(days_supply) < 7,
                        f"Critical product {product_id} has days_of_supply {days_supply} >= 7")

            # Must have sales (units_sold > 0)
            require(units_sold is not None and int(units_sold) > 0,
                    f"Critical product {product_id} has no sales (units_sold={units_sold})")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Healthy Tier Logic ============

def component_10_healthy_tier_logic():
    """Healthy tier must be: top 50% turnover AND stockout_rate < 5% AND days_of_supply 14-90."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        # Get healthy tier products
        healthy_products = execute_query(conn, db_type, f"""
            SELECT product_id, turnover_ratio, stockout_rate, days_of_supply
            FROM {table}
            WHERE LOWER(inventory_health_tier) = 'healthy'
        """)

        if len(healthy_products) == 0:
            return 1.0

        # Get median turnover (50th percentile)
        median_turnover = execute_scalar(conn, db_type, f"""
            SELECT PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY turnover_ratio)
            FROM {table}
            WHERE turnover_ratio IS NOT NULL
        """)

        # All healthy products must meet ALL conditions
        for product_id, turnover, stockout_rate, days_supply in healthy_products:
            # Must be top 50% by turnover (>= median)
            if turnover is not None and median_turnover is not None:
                require(float(turnover) >= float(median_turnover) * 0.9,  # 10% tolerance
                        f"Healthy product {product_id} has turnover {turnover} "
                        f"below median {median_turnover}")

            # Must have stockout_rate < 5%
            if stockout_rate is not None:
                require(float(stockout_rate) < 5,
                        f"Healthy product {product_id} has stockout_rate {stockout_rate} >= 5%")

            # Must have days_of_supply between 14 and 90
            if days_supply is not None:
                require(14 <= float(days_supply) <= 90,
                        f"Healthy product {product_id} has days_of_supply {days_supply} "
                        f"outside range 14-90")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: velocity_score Range ============

def component_11_velocity_score_range():
    """velocity_score must be in valid range (0-100)."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT
                MIN(velocity_score) as min_vs,
                MAX(velocity_score) as max_vs,
                COUNT(CASE WHEN velocity_score < 0 OR velocity_score > 100 THEN 1 END) as out_of_range
            FROM {table}
            WHERE velocity_score IS NOT NULL
        """)

        min_vs, max_vs, out_of_range = result[0]

        require(int(out_of_range) == 0,
                f"Found {out_of_range} velocity_score values outside 0-100 range. "
                f"Min: {min_vs}, Max: {max_vs}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: velocity_score Formula ============

def component_12_velocity_score_formula():
    """Verify velocity_score uses turnover, sell-through, and freshness components."""
    conn, db_type = get_db_connection()
    table = get_table_ref()
    try:
        # Recalculate velocity_score for a sample and compare
        result = execute_query(conn, db_type, f"""
            WITH calculated AS (
                SELECT
                    product_id,
                    velocity_score as actual_score,
                    -- Recalculate using the formula (all components 0-1 scale, then * 100)
                    (
                        COALESCE(PERCENT_RANK() OVER (ORDER BY turnover_ratio), 0) * 0.40 +
                        LEAST(1.0, GREATEST(0.0,
                            COALESCE(units_sold_365d * 1.0 / NULLIF(units_sold_365d + GREATEST(total_quantity_on_hand, 0), 0), 0)
                        )) * 0.30 +
                        CASE
                            WHEN days_since_last_pick <= 7 THEN 1.0
                            WHEN days_since_last_pick <= 30 THEN 0.7
                            WHEN days_since_last_pick <= 90 THEN 0.4
                            ELSE 0.1
                        END * 0.30
                    ) * 100 as expected_score
                FROM {table}
                WHERE velocity_score IS NOT NULL
            )
            SELECT
                COUNT(*) as total,
                COUNT(CASE WHEN ABS(actual_score - expected_score) > 10 THEN 1 END) as mismatches
            FROM calculated
            WHERE expected_score IS NOT NULL
        """)

        total, mismatches = result[0]

        # Allow up to 15% mismatch due to different interpretations
        if total > 0:
            mismatch_rate = int(mismatches) / int(total)
            require(mismatch_rate < 0.15,
                    f"velocity_score formula mismatch: {mismatches}/{total} products "
                    f"({mismatch_rate*100:.1f}%) have > 10 point difference from expected")

        return 1.0
    finally:
        conn.close()


# ============ WEIGHTS AND SCORING ============

WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_tier_column_exists": 1.0,
    "component_5_velocity_score_exists": 1.0,
    "component_6_valid_tier_values": 1.0,
    "component_7_uses_percent_rank": 1.0,
    "component_8_distribution": 1.0,
    "component_9_critical_tier_logic": 1.0,
    "component_10_healthy_tier_logic": 1.0,
    "component_11_velocity_score_range": 1.0,
    "component_12_velocity_score_formula": 1.0,
}


def test_solution():
    """Run all component tests and compute final score."""
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
