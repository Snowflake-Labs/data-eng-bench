"""
Test verifier for dbt-campaign-roi-analysis task.
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


# ============ HELPERS ============


def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Models Compile ============

def component_1_models_compile():
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    result = run_cmd("dbt run -s stg_marketing__campaigns int_marketing__attributed_conversions mart_marketing__campaign_roi")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                roas, ctr, cpc, cpa, revenue_per_impression,
                roas_percentile, cpa_percentile, ctr_percentile,
                campaign_effectiveness_index
            FROM main.mart_marketing__campaign_roi
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None:
                    try:
                        fval = float(val)
                        if math.isinf(fval) or math.isnan(fval):
                            inf_nan_count += 1
                    except (TypeError, ValueError):
                        pass

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Staging Model Columns ============

def component_3_staging_model_columns():
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'campaign_id', 'campaign_name', 'channel', 'start_date', 'end_date',
            'total_budget', 'total_spend', 'total_impressions', 'total_clicks', 'is_active'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.stg_marketing__campaigns LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.stg_marketing__campaigns LIMIT 1")
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Staging model missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Intermediate Model Columns ============

def component_4_intermediate_model_columns():
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'conversion_id', 'campaign_id', 'customer_id', 'session_id',
            'conversion_value', 'order_value', 'attribution_type',
            'attribution_weight', 'attributed_revenue'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.int_marketing__attributed_conversions LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.int_marketing__attributed_conversions LIMIT 1")
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Intermediate model missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Attribution Logic ============

def component_5_attribution_logic():
    """Verify attribution weights are correct"""
    conn, db_type = get_db_connection()
    try:
        # Multi-touch should have weight 1.0
        multi = execute_query(conn, db_type, """
            SELECT attribution_weight FROM main.int_marketing__attributed_conversions
            WHERE attribution_type = 'multi_touch'
            LIMIT 1
        """)

        if multi:
            weight = float(multi[0][0])
            require(weight == 1.0, f"Multi-touch weight should be 1.0, got {weight}")

        # First/last touch should have weight 0.5
        single = execute_query(conn, db_type, """
            SELECT attribution_weight FROM main.int_marketing__attributed_conversions
            WHERE attribution_type IN ('first_touch', 'last_touch')
            LIMIT 1
        """)

        if single:
            weight = float(single[0][0])
            require(weight == 0.5, f"Single touch weight should be 0.5, got {weight}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Mart Model Columns ============

def component_6_mart_model_columns():
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'campaign_id', 'campaign_name', 'channel', 'total_budget', 'total_spend',
            'total_impressions', 'total_clicks', 'total_attributed_conversions',
            'total_attributed_revenue', 'roas', 'ctr', 'cpc', 'cpa', 'revenue_per_impression',
            'roas_percentile', 'cpa_percentile', 'ctr_percentile', 'roi_tier',
            'campaign_effectiveness_index', 'channel_roi_rank', 'channel_peer_count',
            'above_channel_avg_roas'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.mart_marketing__campaign_roi LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.mart_marketing__campaign_roi LIMIT 1")
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Mart model missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 7: ROAS Macro Works ============

def component_7_roas_macro_works():
    """Verify ROAS calculation is correct"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT total_attributed_revenue, total_spend, roas
            FROM main.mart_marketing__campaign_roi
            WHERE total_spend > 0
            LIMIT 5
        """)

        errors = []
        for revenue, spend, roas in results:
            revenue = float(revenue) if revenue is not None else 0
            spend = float(spend) if spend is not None else 0
            roas = float(roas) if roas is not None else 0
            expected_roas = revenue / spend if spend > 0 else 0
            if abs(roas - expected_roas) > 0.01:
                errors.append(f"ROAS={roas:.2f}, expected={expected_roas:.2f}")

        require(len(errors) == 0, f"ROAS calculation errors: {errors}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: CPA Percentile Inverted ============

def component_8_cpa_percentile_inverted():
    """Verify lower CPA = higher percentile"""
    conn, db_type = get_db_connection()
    try:
        # Campaigns with lowest CPA should have high percentiles
        results = execute_query(conn, db_type, """
            SELECT campaign_id, cpa, cpa_percentile
            FROM main.mart_marketing__campaign_roi
            WHERE cpa IS NOT NULL
            ORDER BY cpa ASC
            LIMIT 3
        """)

        for cid, cpa, pct in results:
            cpa = float(cpa) if cpa is not None else 0
            pct = float(pct) if pct is not None else 0
            require(pct >= 0.5,
                    f"Campaign {cid} with low CPA {cpa:.2f} has low percentile {pct:.2f} - should be inverted")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 9: ROI Tier Logic ============

def component_9_roi_tier_logic():
    """Validate waterfall tier classification"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT
                campaign_id,
                roas_percentile,
                roas,
                cpa,
                roi_tier
            FROM main.mart_marketing__campaign_roi
            LIMIT 30
        """)

        errors = []
        for cid, roas_pct, roas, cpa, actual_tier in results:
            roas_pct = float(roas_pct) if roas_pct is not None else 0
            roas = float(roas) if roas is not None else 0
            cpa = float(cpa) if cpa is not None else 999

            # Waterfall logic
            if roas_pct >= 0.75 and roas >= 3.0 and cpa < 50:
                expected = 'high_performer'
            elif roas_pct >= 0.60 or roas >= 2.0:
                expected = 'profitable'
            elif roas >= 1.0 or roas_pct >= 0.40:
                expected = 'break_even'
            else:
                expected = 'underperforming'

            if actual_tier and actual_tier.lower() != expected:
                errors.append(f"campaign {cid}: tier='{actual_tier}', expected='{expected}'")

        require(len(errors) == 0, f"Tier logic errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Effectiveness Index Bounds ============

def component_10_effectiveness_index_bounds():
    """Validate campaign_effectiveness_index is bounded 0-100"""
    conn, db_type = get_db_connection()
    try:
        bounds = execute_query(conn, db_type, """
            SELECT MIN(campaign_effectiveness_index), MAX(campaign_effectiveness_index)
            FROM main.mart_marketing__campaign_roi
        """)

        min_val, max_val = bounds[0]
        min_val = float(min_val) if min_val is not None else None
        max_val = float(max_val) if max_val is not None else None
        if min_val is not None:
            require(min_val >= -0.01, f"campaign_effectiveness_index below 0: {min_val}")
        if max_val is not None:
            require(max_val <= 100.01, f"campaign_effectiveness_index above 100: {max_val}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Channel Peer Rank ============

def component_11_channel_peer_rank():
    """Validate channel_roi_rank is partitioned correctly"""
    conn, db_type = get_db_connection()
    try:
        # Each channel should have rank 1
        result = execute_query(conn, db_type, """
            SELECT channel, MIN(channel_roi_rank) as min_rank
            FROM main.mart_marketing__campaign_roi
            WHERE channel IS NOT NULL
            GROUP BY channel
        """)

        for channel, min_rank in result:
            min_rank = int(min_rank)
            require(min_rank == 1,
                    f"channel {channel}: min channel_roi_rank={min_rank}, expected 1")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Above Channel Avg ROAS ============

def component_12_above_channel_avg_roas():
    """Validate above_channel_avg_roas is calculated correctly"""
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            WITH channel_avgs AS (
                SELECT
                    channel,
                    AVG(roas) as avg_roas
                FROM main.mart_marketing__campaign_roi
                WHERE channel IS NOT NULL
                GROUP BY channel
            )
            SELECT
                c.campaign_id,
                c.channel,
                c.roas,
                c.above_channel_avg_roas,
                ca.avg_roas
            FROM main.mart_marketing__campaign_roi c
            JOIN channel_avgs ca ON c.channel = ca.channel
            LIMIT 20
        """)

        errors = []
        for cid, channel, roas, above_flag, avg_roas in results:
            roas = float(roas) if roas is not None else 0
            avg_roas = float(avg_roas) if avg_roas is not None else 0
            above_flag = int(above_flag) if above_flag is not None else 0
            expected = 1 if roas > avg_roas else 0
            if above_flag != expected:
                errors.append(f"campaign {cid}: above_channel_avg_roas={above_flag}, expected={expected}")

        require(len(errors) == 0, f"above_channel_avg_roas errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


WEIGHTS = {
    "component_1_models_compile": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_staging_model_columns": 1.0,
    "component_4_intermediate_model_columns": 1.0,
    "component_5_attribution_logic": 1.0,
    "component_6_mart_model_columns": 1.0,
    "component_7_roas_macro_works": 1.0,
    "component_8_cpa_percentile_inverted": 1.0,
    "component_9_roi_tier_logic": 1.0,
    "component_10_effectiveness_index_bounds": 1.0,
    "component_11_channel_peer_rank": 1.0,
    "component_12_above_channel_avg_roas": 1.0,
}


def test_solution():
    """Run all 12 campaign ROI validation components and assert a perfect score."""
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
