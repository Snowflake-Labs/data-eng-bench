"""
Test verifier for dbt-warehouse-fulfillment task.

Components:
1. Model compiles and runs successfully
2. No inf/nan values in numeric columns
3. Row count matches warehouses with shipments
4. All required columns exist (including new peer/efficiency columns)
5. fulfillment_tier has valid values
6. volume_tier has valid values
7. Uses PERCENT_RANK() window function for percentile calculation
8. Uses DENSE_RANK() for peer ranking
9. Rate calculations are bounded (0-1 range)
10. Risk score is bounded (0-100 range)
11. Efficiency index is bounded (0-100 range)
12. Elite tier logic correct
13. Volume tier logic correct
14. Peer ranking uses correct partitioning by warehouse_type
15. Peer count matches actual count per warehouse_type
16. Above peer avg flag is correct
17. SLA breach severity follows waterfall logic
18. Efficiency index formula is correct (exact weights)
"""
import subprocess
import os
import re
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
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    """Read the model SQL file."""
    model_path = f"{get_dbt_project_dir()}/models/marts/inventory/rpt_warehouse_fulfillment.sql"
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    """Assert with descriptive message."""
    if not condition:
        raise AssertionError(message)


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    """Model should compile and run without error."""
    result = run_cmd("dbt run -s rpt_warehouse_fulfillment")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """No infinity or NaN values in numeric columns."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                avg_ship_time_days,
                avg_delivery_time_days,
                fulfillment_rate,
                delivery_success_rate,
                on_time_delivery_rate,
                capacity_utilization,
                operational_risk_score,
                efficiency_index,
                peer_percentile
            FROM main.rpt_warehouse_fulfillment
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
    """All warehouses with shipments must be included."""
    conn, db_type = get_db_connection()
    try:
        output_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_warehouse_fulfillment
        """)

        # Count distinct warehouses that have shipments
        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT s.warehouse_id)
            FROM main.stg_orders__shipments s
            INNER JOIN main.stg_inventory__warehouses w ON s.warehouse_id = w.warehouse_id
            WHERE s.warehouse_id IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns Exist ============

def component_4_required_columns():
    """All required columns must exist including new peer/efficiency columns."""
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'warehouse_id', 'warehouse_name', 'warehouse_type',
            'total_orders', 'total_shipped', 'total_delivered',
            'avg_ship_time_days', 'avg_delivery_time_days',
            'fulfillment_rate', 'delivery_success_rate', 'on_time_delivery_rate',
            'capacity_utilization', 'volume_tier', 'fulfillment_tier',
            # New complex columns
            'peer_fulfillment_rank', 'peer_count', 'above_peer_avg', 'peer_percentile',
            'efficiency_index', 'sla_breach_severity', 'operational_risk_score'
        ]

        if db_type == 'snowflake':
            cols = execute_query(conn, db_type, """
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = 'main'
                AND LOWER(table_name) = 'rpt_warehouse_fulfillment'
            """)
            actual_columns = [col[0].lower() for col in cols]
        else:
            result = conn.execute("""
                SELECT * FROM main.rpt_warehouse_fulfillment LIMIT 1
            """).description
            actual_columns = [col[0].lower() for col in result]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Fulfillment Tier Values ============

def component_5_valid_fulfillment_tier_values():
    """fulfillment_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT fulfillment_tier FROM main.rpt_warehouse_fulfillment
        """)

        valid_tiers = {'elite', 'reliable', 'inconsistent', 'struggling'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid fulfillment_tier values found: {invalid}. Expected: {valid_tiers}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Valid Volume Tier Values ============

def component_6_valid_volume_tier_values():
    """volume_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT volume_tier FROM main.rpt_warehouse_fulfillment
        """)

        valid_tiers = {'high_volume', 'moderate', 'low_volume', 'minimal'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid volume_tier values found: {invalid}. Expected: {valid_tiers}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 7: Uses PERCENT_RANK Window Function ============

def component_7_uses_percent_rank():
    """Must use PERCENT_RANK() for percentile-based tier calculation."""
    sql = read_model_file().lower()

    has_percent_rank = 'percent_rank()' in sql or 'percent_rank ()' in sql

    require(has_percent_rank,
            "Must use PERCENT_RANK() window function for percentile tier calculation")
    return 1.0


# ============ COMPONENT 8: Uses DENSE_RANK for Peer Ranking ============

def component_8_uses_dense_rank():
    """Must use DENSE_RANK() for peer ranking within warehouse_type."""
    sql = read_model_file().lower()

    has_dense_rank = 'dense_rank()' in sql or 'dense_rank ()' in sql

    require(has_dense_rank,
            "Must use DENSE_RANK() window function for peer ranking")
    return 1.0


# ============ COMPONENT 9: Rate Bounds ============

def component_9_rate_bounds():
    """All rate columns must be between 0 and 1 (or NULL)."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                MIN(fulfillment_rate) as min_fr,
                MAX(fulfillment_rate) as max_fr,
                MIN(delivery_success_rate) as min_dsr,
                MAX(delivery_success_rate) as max_dsr,
                MIN(on_time_delivery_rate) as min_otdr,
                MAX(on_time_delivery_rate) as max_otdr,
                MIN(peer_percentile) as min_pp,
                MAX(peer_percentile) as max_pp
            FROM main.rpt_warehouse_fulfillment
        """)

        min_fr, max_fr, min_dsr, max_dsr, min_otdr, max_otdr, min_pp, max_pp = result[0]

        if min_fr is not None:
            require(float(min_fr) >= 0, f"fulfillment_rate has negative value: {min_fr}")
        if max_fr is not None:
            require(float(max_fr) <= 1.01, f"fulfillment_rate exceeds 1: {max_fr}")

        if min_dsr is not None:
            require(float(min_dsr) >= 0, f"delivery_success_rate has negative value: {min_dsr}")
        if max_dsr is not None:
            require(float(max_dsr) <= 1.01, f"delivery_success_rate exceeds 1: {max_dsr}")

        if min_otdr is not None:
            require(float(min_otdr) >= 0, f"on_time_delivery_rate has negative value: {min_otdr}")
        if max_otdr is not None:
            require(float(max_otdr) <= 1.01, f"on_time_delivery_rate exceeds 1: {max_otdr}")

        if min_pp is not None:
            require(float(min_pp) >= 0, f"peer_percentile has negative value: {min_pp}")
        if max_pp is not None:
            require(float(max_pp) <= 1.01, f"peer_percentile exceeds 1: {max_pp}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: Risk Score Bounds ============

def component_10_risk_score_bounds():
    """operational_risk_score must be between 0 and 100."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                MIN(operational_risk_score) as min_rs,
                MAX(operational_risk_score) as max_rs,
                COUNT(CASE WHEN operational_risk_score < 0 OR operational_risk_score > 100 THEN 1 END) as out_of_range
            FROM main.rpt_warehouse_fulfillment
            WHERE operational_risk_score IS NOT NULL
        """)

        min_rs, max_rs, out_of_range = result[0]

        require(out_of_range == 0,
                f"Found {out_of_range} operational_risk_score values outside 0-100 range. "
                f"Min: {min_rs}, Max: {max_rs}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Efficiency Index Bounds ============

def component_11_efficiency_index_bounds():
    """efficiency_index must be between 0 and 100."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                MIN(efficiency_index) as min_ei,
                MAX(efficiency_index) as max_ei,
                COUNT(CASE WHEN efficiency_index < 0 OR efficiency_index > 100 THEN 1 END) as out_of_range
            FROM main.rpt_warehouse_fulfillment
            WHERE efficiency_index IS NOT NULL
        """)

        min_ei, max_ei, out_of_range = result[0]

        require(out_of_range == 0,
                f"Found {out_of_range} efficiency_index values outside 0-100 range. "
                f"Min: {min_ei}, Max: {max_ei}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Elite Tier Logic ============

def component_12_elite_tier_logic():
    """Elite tier must be top 25% fulfillment AND delivery > 95% AND on_time > 90%."""
    conn, db_type = get_db_connection()
    try:
        elite = execute_query(conn, db_type, """
            SELECT warehouse_id, fulfillment_rate, delivery_success_rate, on_time_delivery_rate
            FROM main.rpt_warehouse_fulfillment
            WHERE LOWER(fulfillment_tier) = 'elite'
        """)

        if len(elite) == 0:
            return 1.0

        # Get 75th percentile threshold for fulfillment_rate
        threshold = execute_scalar(conn, db_type, """
            SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fulfillment_rate)
            FROM main.rpt_warehouse_fulfillment
        """)

        for row in elite:
            wh_id, fulfillment_rate, delivery_success_rate, on_time_rate = row
            fulfillment_rate = float(fulfillment_rate) if fulfillment_rate is not None else 0
            delivery_success_rate = float(delivery_success_rate) if delivery_success_rate is not None else 0
            on_time_rate = float(on_time_rate) if on_time_rate is not None else 0
            threshold_f = float(threshold) if threshold is not None else 0

            # Must be top 25% (>= 75th percentile with tolerance)
            require(fulfillment_rate >= threshold_f * 0.95,
                    f"Elite warehouse {wh_id} has fulfillment_rate {fulfillment_rate} below threshold {threshold_f}")
            # Must have delivery_success_rate > 95%
            require(delivery_success_rate > 0.95,
                    f"Elite warehouse {wh_id} has delivery_success_rate {delivery_success_rate} <= 95%")
            # Must have on_time_delivery_rate > 90%
            require(on_time_rate > 0.90,
                    f"Elite warehouse {wh_id} has on_time_delivery_rate {on_time_rate} <= 90%")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 13: Volume Tier Logic ============

def component_13_volume_tier_logic():
    """Volume tiers must match utilization thresholds."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                warehouse_id,
                capacity_utilization,
                volume_tier
            FROM main.rpt_warehouse_fulfillment
            WHERE capacity_utilization IS NOT NULL
        """)

        for row in result:
            wh_id, utilization, tier = row
            utilization = float(utilization)
            tier_lower = tier.lower() if tier else None

            if utilization > 0.80:
                require(tier_lower == 'high_volume',
                        f"Warehouse {wh_id} with utilization {utilization} should be high_volume, got {tier}")
            elif utilization >= 0.40:
                require(tier_lower == 'moderate',
                        f"Warehouse {wh_id} with utilization {utilization} should be moderate, got {tier}")
            elif utilization >= 0.10:
                require(tier_lower == 'low_volume',
                        f"Warehouse {wh_id} with utilization {utilization} should be low_volume, got {tier}")
            else:
                require(tier_lower == 'minimal',
                        f"Warehouse {wh_id} with utilization {utilization} should be minimal, got {tier}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 14: Peer Ranking Partitioned by Warehouse Type ============

def component_14_peer_ranking_partitioned():
    """Peer ranking must be partitioned by warehouse_type (rank resets per type)."""
    conn, db_type = get_db_connection()
    try:
        # Check that each warehouse_type has a rank 1
        result = execute_query(conn, db_type, """
            SELECT warehouse_type, MIN(peer_fulfillment_rank) as min_rank
            FROM main.rpt_warehouse_fulfillment
            GROUP BY warehouse_type
        """)

        for row in result:
            wh_type, min_rank = row
            require(int(min_rank) == 1,
                    f"Warehouse type '{wh_type}' has min peer_fulfillment_rank={min_rank}, expected 1. "
                    f"Ranking not properly partitioned by warehouse_type.")

        # Verify rank ordering within each type (higher fulfillment = lower rank number)
        rank_check = execute_scalar(conn, db_type, """
            WITH ranked AS (
                SELECT
                    warehouse_type,
                    warehouse_id,
                    fulfillment_rate,
                    peer_fulfillment_rank,
                    LAG(fulfillment_rate) OVER (
                        PARTITION BY warehouse_type
                        ORDER BY peer_fulfillment_rank
                    ) as prev_rate
                FROM main.rpt_warehouse_fulfillment
            )
            SELECT COUNT(*) as violations
            FROM ranked
            WHERE prev_rate IS NOT NULL
              AND fulfillment_rate > prev_rate + 0.0001
        """)

        require(int(rank_check) == 0,
                f"Found {rank_check} cases where lower rank has lower fulfillment rate - "
                f"rank ordering is incorrect (1 should be best)")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 15: Peer Count Matches Actual ============

def component_15_peer_count_correct():
    """peer_count must match actual count of warehouses per warehouse_type."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            WITH actual_counts AS (
                SELECT warehouse_type, COUNT(*) as actual_count
                FROM main.rpt_warehouse_fulfillment
                GROUP BY warehouse_type
            )
            SELECT
                r.warehouse_id,
                r.warehouse_type,
                r.peer_count,
                a.actual_count
            FROM main.rpt_warehouse_fulfillment r
            JOIN actual_counts a ON r.warehouse_type = a.warehouse_type
            WHERE r.peer_count != a.actual_count
        """)

        require(len(result) == 0,
                f"Found {len(result)} rows with incorrect peer_count. "
                f"peer_count must equal COUNT(*) OVER (PARTITION BY warehouse_type)")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 16: Above Peer Avg Flag Correct ============

def component_16_above_peer_avg_correct():
    """above_peer_avg must be true iff fulfillment_rate > avg of same warehouse_type."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            WITH peer_avgs AS (
                SELECT
                    warehouse_type,
                    AVG(COALESCE(fulfillment_rate, 0)) as type_avg
                FROM main.rpt_warehouse_fulfillment
                GROUP BY warehouse_type
            )
            SELECT
                r.warehouse_id,
                r.fulfillment_rate,
                r.above_peer_avg,
                p.type_avg,
                CASE
                    WHEN COALESCE(r.fulfillment_rate, 0) > p.type_avg THEN true
                    ELSE false
                END as expected_flag
            FROM main.rpt_warehouse_fulfillment r
            JOIN peer_avgs p ON r.warehouse_type = p.warehouse_type
            WHERE r.above_peer_avg != (CASE WHEN COALESCE(r.fulfillment_rate, 0) > p.type_avg THEN true ELSE false END)
        """)

        require(len(result) == 0,
                f"Found {len(result)} rows with incorrect above_peer_avg flag. "
                f"Flag must be true when fulfillment_rate > peer group average.")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 17: SLA Breach Severity Waterfall ============

def component_17_sla_breach_severity_logic():
    """SLA breach severity must follow exact waterfall logic."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                warehouse_id,
                COALESCE(fulfillment_rate, 0) as fr,
                COALESCE(delivery_success_rate, 0) as dsr,
                COALESCE(on_time_delivery_rate, 0) as otdr,
                LOWER(sla_breach_severity) as severity
            FROM main.rpt_warehouse_fulfillment
        """)

        valid_severities = {'critical', 'high', 'medium', 'low', 'none'}

        for row in result:
            wh_id, fr, dsr, otdr, severity = row
            fr = float(fr)
            dsr = float(dsr)
            otdr = float(otdr)

            require(severity in valid_severities,
                    f"Warehouse {wh_id} has invalid sla_breach_severity: {severity}")

            # Calculate expected severity using waterfall logic
            if fr < 0.50 or dsr < 0.70 or otdr < 0.50:
                expected = 'critical'
            elif fr < 0.70 or dsr < 0.80 or otdr < 0.60:
                expected = 'high'
            elif fr < 0.85 or dsr < 0.90 or otdr < 0.75:
                expected = 'medium'
            elif fr < 0.95 or dsr < 0.95 or otdr < 0.85:
                expected = 'low'
            else:
                expected = 'none'

            require(severity == expected,
                    f"Warehouse {wh_id}: sla_breach_severity={severity}, expected={expected}. "
                    f"Rates: fulfillment={fr:.2f}, delivery={dsr:.2f}, on_time={otdr:.2f}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 18: Efficiency Index Formula ============

def component_18_efficiency_index_formula():
    """Efficiency index must use exact weighted formula."""
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT
                warehouse_id,
                COALESCE(fulfillment_rate, 0) as fr,
                COALESCE(delivery_success_rate, 0) as dsr,
                COALESCE(on_time_delivery_rate, 0) as otdr,
                COALESCE(avg_ship_time_days, 0) as ship_days,
                efficiency_index
            FROM main.rpt_warehouse_fulfillment
            WHERE efficiency_index IS NOT NULL
        """)

        for row in result:
            wh_id, fr, dsr, otdr, ship_days, actual_ei = row
            fr = float(fr)
            dsr = float(dsr)
            otdr = float(otdr)
            ship_days = float(ship_days)
            actual_ei = float(actual_ei)

            # Calculate expected using exact formula:
            # (fr*0.30 + dsr*0.25 + otdr*0.25 + (1 - min(ship_days/14, 1))*0.20) * 100
            shipping_component = 1.0 - min(ship_days / 14.0, 1.0)
            expected_ei = (fr * 0.30 + dsr * 0.25 + otdr * 0.25 + shipping_component * 0.20) * 100
            expected_ei = max(0, min(100, expected_ei))  # Bound 0-100

            # Allow small tolerance for rounding
            diff = abs(actual_ei - expected_ei)
            require(diff < 0.5,
                    f"Warehouse {wh_id}: efficiency_index={actual_ei:.2f}, expected={expected_ei:.2f} (diff={diff:.2f}). "
                    f"Formula: (fr*0.30 + dsr*0.25 + otdr*0.25 + ship_speed*0.20) * 100. "
                    f"Values: fr={fr:.4f}, dsr={dsr:.4f}, otdr={otdr:.4f}, ship_days={ship_days:.2f}")

        return 1.0
    finally:
        conn.close()


# ============ WEIGHTS AND SCORING ============

WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_valid_fulfillment_tier_values": 1.0,
    "component_6_valid_volume_tier_values": 1.0,
    "component_7_uses_percent_rank": 1.0,
    "component_8_uses_dense_rank": 1.0,
    "component_9_rate_bounds": 1.0,
    "component_10_risk_score_bounds": 1.0,
    "component_11_efficiency_index_bounds": 1.0,
    "component_12_elite_tier_logic": 1.0,
    "component_13_volume_tier_logic": 1.0,
    "component_14_peer_ranking_partitioned": 1.0,
    "component_15_peer_count_correct": 1.0,
    "component_16_above_peer_avg_correct": 1.0,
    "component_17_sla_breach_severity_logic": 1.0,
    "component_18_efficiency_index_formula": 1.0,
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
