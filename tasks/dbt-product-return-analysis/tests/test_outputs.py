"""
Test verifier for dbt-product-return-analysis task.

Components:
1. Model compiles and runs successfully
2. No inf/nan values in output
3. Row count matches products with sales
4. All required columns exist
5. return_risk_tier has valid values
6. Uses window function for percentile calculation
7. Tier distribution is reasonable (multiple tiers, no tier > 80%)
8. High risk tier logic correct (top 15% + returned > 5)
9. Return rate bounded (0-1 range)
10. Minimal risk tier has zero returns
11. Moderate risk tier logic correct (top 40% OR lost > 1000, but not high_risk)
12. Low risk tier logic correct (has returns but not moderate/high)
13. Lost revenue calculation is correct
"""
import subprocess
import math
import json
import os
import re
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
    """Create a database connection based on DB_TYPE environment variable."""
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
        conn = duckdb.connect("/app/database/retail.duckdb", read_only=True)
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




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    """Read the model SQL file."""
    model_path = f"{get_dbt_project_dir()}/models/marts/product/rpt_product_returns.sql"
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    """Assert with descriptive message."""
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    """Model should compile and run without error."""
    result = run_cmd("dbt run -s rpt_product_returns")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """No infinity or NaN values in numeric columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                return_rate,
                avg_days_to_return,
                lost_revenue
            FROM main.rpt_product_returns
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None:
                    try:
                        if math.isinf(float(val)) or math.isnan(float(val)):
                            inf_nan_count += 1
                    except (TypeError, ValueError, OverflowError):
                        pass

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled properly")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    """All products with sales must be included (within +/-5% tolerance)."""
    conn, db_type = get_db_connection()
    try:
        output_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_product_returns
        """)

        # Count distinct products that have been sold (using intermediate models)
        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT ol.product_id)
            FROM main.int_sales__order_lines ol
            INNER JOIN main.int_sales__orders_enriched o ON ol.order_id = o.order_id
            INNER JOIN main.stg_product__products p ON ol.product_id = p.product_id
            WHERE o.status != 'CANCELLED'
              AND ol.product_id IS NOT NULL
        """)

        require(source_count and source_count > 0,
                f"expected product count is 0 - source product_id not populated")
        tol = max(5, int(source_count * 0.05))
        require(abs(output_count - source_count) <= tol,
                f"Row count out of tolerance: output={output_count}, expected={source_count} (+/-{tol})")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns Exist ============

def component_4_required_columns():
    """All required columns must exist."""
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'product_id', 'product_name', 'category', 'total_sold', 'total_orders',
            'total_returned', 'total_return_requests', 'return_rate',
            'avg_days_to_return', 'revenue', 'lost_revenue', 'return_risk_tier'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.rpt_product_returns LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("""
                SELECT * FROM main.rpt_product_returns LIMIT 1
            """).description
            actual_columns = [col[0].lower() for col in result]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Tier Values ============

def component_5_valid_tier_values():
    """return_risk_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT return_risk_tier FROM main.rpt_product_returns
        """)

        valid_tiers = {'high_risk', 'moderate_risk', 'low_risk', 'minimal_risk'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid tier values found: {invalid}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Uses Window Function ============

def component_6_uses_window_function():
    """Must use PERCENT_RANK() or NTILE() for percentile-based tier calculation."""
    sql = read_model_file().lower()

    has_percent_rank = 'percent_rank()' in sql or 'percent_rank ()' in sql
    has_ntile = 'ntile(' in sql

    require(has_percent_rank or has_ntile,
            "Must use PERCENT_RANK() or NTILE() window function for tier calculation")
    return 1.0


# ============ COMPONENT 7: Tier Distribution ============

def component_7_tier_distribution():
    """Tiers must have reasonable distribution (not all same tier)."""
    conn, db_type = get_db_connection()
    try:
        total_rows = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_product_returns
        """)

        # Skip this check if table is empty (no source data)
        if total_rows == 0:
            return 1.0

        result = execute_query(conn, db_type, """
            SELECT return_risk_tier, COUNT(*) as cnt
            FROM main.rpt_product_returns
            WHERE return_risk_tier IS NOT NULL
            GROUP BY return_risk_tier
        """)

        tier_counts = {row[0].lower(): row[1] for row in result}

        # Must have at least 2 different tiers
        require(len(tier_counts) >= 2,
                f"Only {len(tier_counts)} tier(s) found - classification logic may be wrong")

        # No single tier should contain more than 80% of products
        for tier, count in tier_counts.items():
            pct = count / total_rows
            require(pct <= 0.80,
                    f"Tier '{tier}' contains {pct*100:.1f}% of products - distribution is unreasonable")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: High Risk Tier Logic ============

def component_8_high_risk_tier_logic():
    """High risk must be top 15% by return_rate AND total_returned > 5."""
    conn, db_type = get_db_connection()
    try:
        # Get high risk products
        high_risk = execute_query(conn, db_type, """
            SELECT product_id, return_rate, total_returned
            FROM main.rpt_product_returns
            WHERE LOWER(return_risk_tier) = 'high_risk'
        """)

        if len(high_risk) == 0:
            # No high risk is acceptable if no one qualifies
            return 1.0

        # Get 85th percentile threshold for return_rate
        threshold = execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.85) WITHIN GROUP (ORDER BY return_rate)
            FROM main.rpt_product_returns
            WHERE return_rate IS NOT NULL
        """)

        # All high risk products must meet both conditions
        for prod_id, return_rate, total_returned in high_risk:
            # Must be top 15% (>= 85th percentile) - no tolerance
            require(return_rate is not None and return_rate >= threshold,
                    f"High risk product {prod_id} has return_rate {return_rate} below threshold {threshold}")
            # Must have total_returned > 5
            require(total_returned is not None and total_returned > 5,
                    f"High risk product {prod_id} has total_returned {total_returned} <= 5")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 9: Return Rate Bounds ============

def component_9_return_rate_bounds():
    """Return rate must be non-negative and finite (can exceed 1 when cross-period returns > in-period sales)."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                MIN(return_rate) as min_rate,
                MAX(return_rate) as max_rate
            FROM main.rpt_product_returns
        """)

        min_rate, max_rate = result[0]

        if min_rate is not None:
            require(min_rate >= 0, f"return_rate has negative value: {min_rate}")
        if max_rate is not None:
            require(not math.isinf(float(max_rate)) and not math.isnan(float(max_rate)),
                    f"return_rate is infinite or NaN: {max_rate}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Minimal Risk Has Zero Returns ============

def component_10_minimal_risk_zero_returns():
    """Minimal risk tier must have zero returns."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT product_id, total_returned
            FROM main.rpt_product_returns
            WHERE LOWER(return_risk_tier) = 'minimal_risk'
              AND total_returned > 0
        """)

        require(len(result) == 0,
                f"Found {len(result)} minimal_risk products with returns > 0")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Moderate Risk Tier Logic ============

def component_11_moderate_risk_tier_logic():
    """Moderate risk must be top 40% by return_rate OR lost_revenue > 1000 (but not high_risk)."""
    conn, db_type = get_db_connection()
    try:
        # Get 60th percentile threshold (top 40% means >= 60th percentile)
        threshold_60 = execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.60) WITHIN GROUP (ORDER BY return_rate)
            FROM main.rpt_product_returns
            WHERE return_rate IS NOT NULL
        """)

        # Get 85th percentile threshold for high_risk boundary
        threshold_85 = execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.85) WITHIN GROUP (ORDER BY return_rate)
            FROM main.rpt_product_returns
            WHERE return_rate IS NOT NULL
        """)

        # Check moderate_risk products meet criteria
        moderate_risk = execute_query(conn, db_type, """
            SELECT product_id, return_rate, total_returned, lost_revenue
            FROM main.rpt_product_returns
            WHERE LOWER(return_risk_tier) = 'moderate_risk'
        """)

        for prod_id, return_rate, total_returned, lost_revenue in moderate_risk:
            # Must meet at least one moderate_risk condition
            is_top_40_rate = return_rate is not None and return_rate >= threshold_60
            is_high_lost_revenue = lost_revenue is not None and lost_revenue > 1000

            require(is_top_40_rate or is_high_lost_revenue,
                    f"Moderate risk product {prod_id} doesn't meet criteria: rate={return_rate}, lost={lost_revenue}")

            # Must NOT qualify for high_risk (top 15% AND total_returned > 5)
            is_top_15_rate = return_rate is not None and return_rate >= threshold_85
            would_be_high_risk = is_top_15_rate and (total_returned is not None and total_returned > 5)

            require(not would_be_high_risk,
                    f"Moderate risk product {prod_id} should be high_risk: rate={return_rate}, returned={total_returned}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Low Risk Tier Logic ============

def component_12_low_risk_tier_logic():
    """Low risk must have returns but not qualify for higher tiers."""
    conn, db_type = get_db_connection()
    try:
        # Get thresholds
        threshold_60 = execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.60) WITHIN GROUP (ORDER BY return_rate)
            FROM main.rpt_product_returns
            WHERE return_rate IS NOT NULL
        """)

        # Check low_risk products
        low_risk = execute_query(conn, db_type, """
            SELECT product_id, return_rate, total_returned, lost_revenue
            FROM main.rpt_product_returns
            WHERE LOWER(return_risk_tier) = 'low_risk'
        """)

        for prod_id, return_rate, total_returned, lost_revenue in low_risk:
            # Must have some returns
            require(total_returned is not None and total_returned > 0,
                    f"Low risk product {prod_id} has no returns: total_returned={total_returned}")

            # Must NOT qualify for moderate_risk (top 40% OR lost > 1000)
            is_top_40_rate = return_rate is not None and return_rate >= threshold_60
            is_high_lost_revenue = lost_revenue is not None and lost_revenue > 1000

            require(not is_top_40_rate and not is_high_lost_revenue,
                    f"Low risk product {prod_id} should be moderate_risk: rate={return_rate}, lost={lost_revenue}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 13: Lost Revenue Calculation ============

def component_13_lost_revenue_calculation():
    """Lost revenue should be proportional to returns."""
    conn, db_type = get_db_connection()
    try:
        # Check that lost_revenue is calculated correctly
        # lost_revenue = revenue * (total_returned / total_sold)
        result = execute_query(conn, db_type, """
            SELECT
                product_id,
                revenue,
                total_sold,
                total_returned,
                lost_revenue,
                ABS(lost_revenue - (revenue * total_returned * 1.0 / NULLIF(total_sold, 0))) as diff
            FROM main.rpt_product_returns
            WHERE total_returned > 0
              AND total_sold > 0
              AND lost_revenue IS NOT NULL
        """)

        # Allow small floating point tolerance
        for row in result:
            prod_id, revenue, total_sold, total_returned, lost_revenue, diff = row
            if diff is not None:
                require(diff < 0.01,
                        f"Product {prod_id}: lost_revenue calculation incorrect, diff={diff}")

        return 1.0
    finally:
        conn.close()


# ============ WEIGHTS AND SCORING ============

WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_valid_tier_values": 1.0,
    "component_6_uses_window_function": 1.0,
    "component_7_tier_distribution": 1.0,
    "component_8_high_risk_tier_logic": 1.0,
    "component_9_return_rate_bounds": 1.0,
    "component_10_minimal_risk_zero_returns": 1.0,
    "component_11_moderate_risk_tier_logic": 1.0,
    "component_12_low_risk_tier_logic": 1.0,
    "component_13_lost_revenue_calculation": 1.0,
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
