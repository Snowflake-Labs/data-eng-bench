"""
Test verifier for dbt-carrier-delivery-performance task.
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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def get_connection():
    conn, db_type = get_db_connection()
    return conn, db_type


def read_model_file():
    model_path = f"{get_dbt_project_dir()}/models/marts/sales/rpt_carrier_performance.sql"
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    result = run_cmd("dbt run -s rpt_carrier_performance")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    conn, db_type = get_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                avg_shipping_cost, avg_weight, avg_delivery_days,
                on_time_delivery_rate, delivery_completion_rate,
                carrier_efficiency_index, carrier_reliability_index,
                speed_percentile, cost_percentile, peer_speed_percentile
            FROM main.rpt_carrier_performance
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                if val is not None and isinstance(val, float) and (math.isinf(val) or math.isnan(val)):
                    inf_nan_count += 1

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    conn, db_type = get_connection()
    try:
        output_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_carrier_performance
        """)

        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT carrier_id)
            FROM main.stg_orders__shipments
            WHERE carrier_id IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count} - check WHERE clause")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns ============

def component_4_required_columns():
    conn, db_type = get_connection()
    try:
        required_columns = [
            'carrier_id', 'shipping_method_id', 'total_shipments', 'delivered_shipments',
            'in_transit_shipments', 'cancelled_shipments', 'total_shipping_cost',
            'avg_shipping_cost', 'total_weight', 'avg_weight', 'avg_delivery_days',
            'min_delivery_days', 'max_delivery_days', 'on_time_shipments',
            'on_time_delivery_rate', 'delivery_completion_rate',
            'speed_percentile', 'cost_percentile',
            'delivery_speed_tier', 'cost_tier',
            'peer_rank', 'peer_count', 'above_peer_avg', 'peer_speed_percentile',
            'carrier_efficiency_index', 'carrier_reliability_index'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.rpt_carrier_performance LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.rpt_carrier_performance LIMIT 1")
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Tier Values ============

def component_5_valid_tier_values():
    conn, db_type = get_connection()
    try:
        # Check delivery_speed_tier
        result = execute_query(conn, db_type, """
            SELECT DISTINCT delivery_speed_tier FROM main.rpt_carrier_performance
        """)
        valid_tiers = {'critical', 'needs_improvement', 'good', 'excellent'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}
        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid delivery_speed_tier values: {invalid}")

        # Check cost_tier
        result = execute_query(conn, db_type, """
            SELECT DISTINCT cost_tier FROM main.rpt_carrier_performance
        """)
        valid_cost_tiers = {'premium', 'economical', 'standard', 'expensive'}
        actual_cost_tiers = {row[0].lower() if row[0] else None for row in result}
        invalid_cost = actual_cost_tiers - valid_cost_tiers - {None}
        require(len(invalid_cost) == 0, f"Invalid cost_tier values: {invalid_cost}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Speed Percentile Validation ============

def component_6_speed_percentile_validation():
    """Validate speed_percentile: faster carriers (lower days) should have HIGHER percentile"""
    conn, db_type = get_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT carrier_id, avg_delivery_days, speed_percentile
            FROM main.rpt_carrier_performance
            WHERE avg_delivery_days IS NOT NULL AND speed_percentile IS NOT NULL
            ORDER BY avg_delivery_days ASC
            LIMIT 5
        """)

        # Fastest carriers should have high percentile (close to 1)
        for cid, days, pct in results[:3]:
            require(pct >= 0.5,
                    f"Fastest carrier {cid} (days={days}) has low speed_percentile={pct:.2f} - ORDER BY direction wrong")

        # Also check slowest carriers have low percentile
        slowest = execute_query(conn, db_type, """
            SELECT carrier_id, avg_delivery_days, speed_percentile
            FROM main.rpt_carrier_performance
            WHERE avg_delivery_days IS NOT NULL AND speed_percentile IS NOT NULL
            ORDER BY avg_delivery_days DESC
            LIMIT 3
        """)

        for cid, days, pct in slowest:
            require(pct <= 0.5,
                    f"Slowest carrier {cid} (days={days}) has high speed_percentile={pct:.2f} - ORDER BY direction wrong")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 7: Cost Percentile Validation ============

def component_7_cost_percentile_validation():
    """Validate cost_percentile: cheaper carriers should have HIGHER percentile"""
    conn, db_type = get_connection()
    try:
        results = execute_query(conn, db_type, """
            SELECT carrier_id, avg_shipping_cost, cost_percentile
            FROM main.rpt_carrier_performance
            WHERE avg_shipping_cost IS NOT NULL AND cost_percentile IS NOT NULL
            ORDER BY avg_shipping_cost ASC
            LIMIT 5
        """)

        # Cheapest carriers should have high percentile (close to 1)
        for cid, cost, pct in results[:3]:
            require(pct >= 0.5,
                    f"Cheapest carrier {cid} (cost={cost}) has low cost_percentile={pct:.2f} - ORDER BY direction wrong")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: Waterfall Tier Logic ============

def component_8_waterfall_tier_logic():
    conn, db_type = get_connection()
    try:
        results = execute_query(conn, db_type, """
            WITH delivery_pct AS (
                SELECT
                    carrier_id,
                    PERCENT_RANK() OVER (ORDER BY avg_delivery_days DESC) as slow_pct
                FROM main.rpt_carrier_performance
                WHERE avg_delivery_days IS NOT NULL
            )
            SELECT
                r.carrier_id,
                r.avg_delivery_days,
                r.on_time_delivery_rate,
                r.delivery_speed_tier,
                COALESCE(p.slow_pct, 0.5) as slow_percentile
            FROM main.rpt_carrier_performance r
            LEFT JOIN delivery_pct p ON r.carrier_id = p.carrier_id
            LIMIT 50
        """)

        errors = []
        for cid, avg_days, on_time_rate, actual_tier, slow_pct in results:
            avg_days = avg_days if avg_days is not None else 999
            on_time_rate = on_time_rate or 0

            # Waterfall logic
            if slow_pct <= 0.30 and avg_days > 8:
                expected = 'critical'
            elif slow_pct <= 0.60 or on_time_rate < 0.75:
                expected = 'needs_improvement'
            elif slow_pct >= 0.80 and on_time_rate >= 0.92:
                expected = 'excellent'
            elif on_time_rate >= 0.85 and avg_days <= 5:
                expected = 'good'
            else:
                expected = 'good'

            if actual_tier and actual_tier.lower() != expected:
                errors.append(f"carrier {cid}: tier='{actual_tier}', expected='{expected}' "
                            f"(days={avg_days:.1f}, rate={on_time_rate:.2f}, slow_pct={slow_pct:.2f})")

        require(len(errors) == 0, f"Tier logic errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 9: Cost Tier Waterfall Logic ============

def component_9_cost_tier_logic():
    """Validate cost_tier waterfall classification"""
    conn, db_type = get_connection()
    try:
        median_cost = float(execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_shipping_cost)
            FROM main.rpt_carrier_performance
            WHERE avg_shipping_cost IS NOT NULL
        """) or 1)

        results = execute_query(conn, db_type, """
            SELECT
                carrier_id,
                cost_percentile,
                delivery_completion_rate,
                avg_shipping_cost,
                cost_tier
            FROM main.rpt_carrier_performance
            WHERE cost_percentile IS NOT NULL
            LIMIT 40
        """)

        errors = []
        for cid, cost_pct, completion_rate, avg_cost, actual_tier in results:
            completion_rate = completion_rate or 0
            avg_cost = avg_cost or median_cost

            # Waterfall logic for cost_tier
            if cost_pct >= 0.80 and completion_rate >= 0.90:
                expected = 'premium'
            elif cost_pct >= 0.60 and avg_cost < median_cost:
                expected = 'economical'
            elif cost_pct >= 0.30:
                expected = 'standard'
            else:
                expected = 'expensive'

            if actual_tier and actual_tier.lower() != expected:
                errors.append(f"carrier {cid}: cost_tier='{actual_tier}', expected='{expected}' "
                            f"(cost_pct={cost_pct:.2f}, completion={completion_rate:.2f}, cost={avg_cost:.2f})")

        require(len(errors) == 0, f"Cost tier logic errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Peer Rank Validation ============

def component_10_peer_rank_validation():
    """Validate peer_rank is partitioned correctly by shipping_method_id"""
    conn, db_type = get_connection()
    try:
        # Check that each shipping method has rank 1
        result = execute_query(conn, db_type, """
            SELECT shipping_method_id, MIN(peer_rank) as min_rank
            FROM main.rpt_carrier_performance
            WHERE shipping_method_id IS NOT NULL
            GROUP BY shipping_method_id
        """)

        for method_id, min_rank in result:
            require(min_rank == 1,
                    f"shipping_method_id {method_id}: min peer_rank={min_rank}, expected 1 - not partitioned correctly")

        # Validate peer_count matches actual count per shipping method
        count_check = execute_query(conn, db_type, """
            SELECT r.shipping_method_id, r.peer_count, COUNT(*) as actual_count
            FROM main.rpt_carrier_performance r
            WHERE r.shipping_method_id IS NOT NULL
            GROUP BY r.shipping_method_id, r.peer_count
            HAVING r.peer_count != COUNT(*)
        """)

        require(len(count_check) == 0,
                f"peer_count mismatch: {count_check[:3]}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Peer Speed Percentile Validation ============

def component_11_peer_speed_percentile_validation():
    """Validate peer_speed_percentile is partitioned by shipping_method_id and ordered correctly"""
    conn, db_type = get_connection()
    try:
        # Check that within each shipping method, faster carriers have higher peer_speed_percentile
        # Only check groups with more than 1 carrier (PERCENT_RANK returns 0 for single-element partitions)
        results = execute_query(conn, db_type, """
            WITH ranked AS (
                SELECT
                    shipping_method_id,
                    carrier_id,
                    avg_delivery_days,
                    peer_speed_percentile,
                    peer_count,
                    ROW_NUMBER() OVER (PARTITION BY shipping_method_id ORDER BY avg_delivery_days ASC) as speed_rank
                FROM main.rpt_carrier_performance
                WHERE shipping_method_id IS NOT NULL
                AND avg_delivery_days IS NOT NULL
                AND peer_speed_percentile IS NOT NULL
            )
            SELECT shipping_method_id, carrier_id, avg_delivery_days, peer_speed_percentile, speed_rank, peer_count
            FROM ranked
            WHERE speed_rank = 1 AND peer_count > 1
        """)

        # Fastest carrier in each group should have high peer_speed_percentile
        for method_id, cid, days, pct, _, peer_count in results:
            require(pct >= 0.7,
                    f"shipping_method {method_id}: fastest carrier {cid} (days={days}) has peer_speed_percentile={pct:.2f}, expected >= 0.7 (peer_count={peer_count})")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Above Peer Avg Validation ============

def component_12_above_peer_avg_validation():
    """Validate above_peer_avg is calculated correctly"""
    conn, db_type = get_connection()
    try:
        results = execute_query(conn, db_type, """
            WITH peer_avgs AS (
                SELECT
                    shipping_method_id,
                    AVG(on_time_delivery_rate) as peer_avg_rate
                FROM main.rpt_carrier_performance
                WHERE shipping_method_id IS NOT NULL
                GROUP BY shipping_method_id
            )
            SELECT
                r.carrier_id,
                r.on_time_delivery_rate,
                r.above_peer_avg,
                p.peer_avg_rate
            FROM main.rpt_carrier_performance r
            JOIN peer_avgs p ON r.shipping_method_id = p.shipping_method_id
            LIMIT 30
        """)

        errors = []
        for cid, rate, above_flag, peer_avg in results:
            rate = rate or 0
            expected = 1 if rate > peer_avg else 0
            if above_flag != expected:
                errors.append(f"carrier {cid}: above_peer_avg={above_flag}, expected={expected} "
                            f"(rate={rate:.3f}, peer_avg={peer_avg:.3f})")

        require(len(errors) == 0, f"above_peer_avg errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 13: Efficiency Index Bounds ============

def component_13_efficiency_index_bounds():
    """Validate carrier_efficiency_index is bounded 0-100"""
    conn, db_type = get_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT MIN(carrier_efficiency_index), MAX(carrier_efficiency_index)
            FROM main.rpt_carrier_performance
        """)
        bounds = rows[0]

        min_val, max_val = bounds
        if min_val is not None:
            require(min_val >= -0.01, f"carrier_efficiency_index below 0: {min_val}")
        if max_val is not None:
            require(max_val <= 100.01, f"carrier_efficiency_index above 100: {max_val}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 14: Efficiency Index Formula ============

def component_14_efficiency_index_formula():
    """Validate efficiency index formula"""
    conn, db_type = get_connection()
    try:
        median_cost = float(execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_shipping_cost)
            FROM main.rpt_carrier_performance
            WHERE avg_shipping_cost IS NOT NULL
        """) or 1)

        results = execute_query(conn, db_type, """
            SELECT
                carrier_id,
                delivery_completion_rate,
                avg_delivery_days,
                on_time_delivery_rate,
                avg_shipping_cost,
                carrier_efficiency_index
            FROM main.rpt_carrier_performance
            WHERE carrier_efficiency_index IS NOT NULL
            LIMIT 20
        """)

        errors = []
        for cid, fulfillment, avg_days, on_time, cost, actual_index in results:
            fulfillment = float(fulfillment or 0)
            avg_days = float(avg_days if avg_days is not None else 14)
            on_time = float(on_time or 0)
            cost = float(cost if cost is not None else median_cost)

            fulfillment_factor = min(1, max(0, fulfillment))
            speed_factor = max(0, 1 - min(avg_days / 14.0, 1.0))
            on_time_factor = min(1, max(0, on_time))
            cost_factor = max(0, min(1, 1 - (cost / median_cost - 1)))

            expected = (fulfillment_factor * 0.30 +
                       speed_factor * 0.25 +
                       on_time_factor * 0.25 +
                       cost_factor * 0.20) * 100

            if abs(float(actual_index) - expected) > 2.0:
                errors.append(f"carrier {cid}: index={float(actual_index):.2f}, expected={expected:.2f}")

        require(len(errors) == 0, f"Efficiency index formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 15: Reliability Index Bounds ============

def component_15_reliability_index_bounds():
    """Validate carrier_reliability_index is bounded 0-100"""
    conn, db_type = get_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT MIN(carrier_reliability_index), MAX(carrier_reliability_index)
            FROM main.rpt_carrier_performance
        """)
        bounds = rows[0]

        min_val, max_val = bounds
        if min_val is not None:
            require(min_val >= -0.01, f"carrier_reliability_index below 0: {min_val}")
        if max_val is not None:
            require(max_val <= 100.01, f"carrier_reliability_index above 100: {max_val}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 16: Reliability Index Formula ============

def component_16_reliability_index_formula():
    """Validate reliability index formula"""
    conn, db_type = get_connection()
    try:
        median_volume = execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_shipments)
            FROM main.rpt_carrier_performance
            WHERE total_shipments IS NOT NULL
        """) or 1
        median_volume = float(median_volume)

        results = execute_query(conn, db_type, """
            SELECT
                carrier_id,
                delivery_completion_rate,
                avg_delivery_days,
                min_delivery_days,
                max_delivery_days,
                total_shipments,
                carrier_reliability_index
            FROM main.rpt_carrier_performance
            WHERE carrier_reliability_index IS NOT NULL
            LIMIT 20
        """)

        errors = []
        for cid, completion, avg_days, min_days, max_days, volume, actual_index in results:
            completion = float(completion or 0)
            avg_days = float(avg_days if avg_days is not None else 1)
            min_days = float(min_days if min_days is not None else 0)
            max_days = float(max_days if max_days is not None else 0)
            volume = float(volume or 0)
            actual_index = float(actual_index or 0)

            # Completion consistency (40%)
            completion_factor = min(1, max(0, completion))

            # Speed consistency (30%): lower variance = better
            # variance = (max - min) / avg, normalized
            if avg_days > 0:
                variance_ratio = (max_days - min_days) / avg_days
                speed_consistency = max(0, 1 - min(variance_ratio / 2.0, 1.0))
            else:
                speed_consistency = 1.0

            # Volume handling (30%): relative to median
            volume_factor = min(1, volume / median_volume)

            expected = (completion_factor * 0.40 +
                       speed_consistency * 0.30 +
                       volume_factor * 0.30) * 100

            if abs(actual_index - expected) > 3.0:
                errors.append(f"carrier {cid}: reliability_index={actual_index:.2f}, expected={expected:.2f}")

        require(len(errors) == 0, f"Reliability index formula errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_valid_tier_values": 1.0,
    "component_6_speed_percentile_validation": 1.0,
    "component_7_cost_percentile_validation": 1.0,
    "component_8_waterfall_tier_logic": 1.0,
    "component_9_cost_tier_logic": 1.0,
    "component_10_peer_rank_validation": 1.0,
    "component_11_peer_speed_percentile_validation": 1.0,
    "component_12_above_peer_avg_validation": 1.0,
    "component_13_efficiency_index_bounds": 1.0,
    "component_14_efficiency_index_formula": 1.0,
    "component_15_reliability_index_bounds": 1.0,
    "component_16_reliability_index_formula": 1.0,
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
