"""
Test verifier for dbt-campaign-performance task.

Components:
1. Model compiles and runs successfully
2. No inf/nan values in output
3. Row count matches campaigns with email events
4. All required columns exist (including channel_category and peer metrics)
5. campaign_tier has valid values
6. channel_category correctly assigned based on channel name
7. Peer metrics partitioned by channel_category correctly
8. Uses DENSE_RANK for category_conversion_rank
9. Uses PERCENT_RANK for category_revenue_percentile
10. above_category_avg_conversion correctly calculated
11. performance_index bounded 0-100 and formula validated
12. Waterfall tier logic validated
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


# ============ HELPERS ============


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


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
    dbt_project_dir = get_dbt_project_dir()
    model_path = os.path.join(dbt_project_dir, "models/marts/marketing/rpt_campaign_performance.sql")
    with open(model_path, "r") as f:
        return f.read()


def require(condition, message):
    """Assert with descriptive message."""
    if not condition:
        raise AssertionError(message)





def get_schema_prefix():
    """Get the schema prefix for queries based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return ''
    else:
        return 'main.'


# ============ COMPONENT 1: Model Compiles ============

def component_1_model_compiles():
    """Model should compile and run without error."""
    dbt_project_dir = get_dbt_project_dir()
    result = run_cmd(f"dbt run -s rpt_campaign_performance --profiles-dir {dbt_project_dir}", cwd=dbt_project_dir)
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    """No infinity or NaN values in numeric columns."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT
                open_rate,
                click_rate,
                conversion_rate,
                attributed_revenue,
                revenue_per_conversion,
                category_revenue_percentile,
                performance_index
            FROM {prefix}rpt_campaign_performance
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

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled properly")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    """All campaigns with email events must be included."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        output_count = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {prefix}rpt_campaign_performance
        """)

        source_count = execute_scalar(conn, db_type, f"""
            SELECT COUNT(DISTINCT e.campaign_id)
            FROM {prefix}stg_marketing__email_events e
            INNER JOIN {prefix}stg_marketing__campaigns c ON e.campaign_id = c.campaign_id
            WHERE e.campaign_id IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns Exist ============

def component_4_required_columns():
    """All required columns must exist including channel_category and peer metrics."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        required_columns = [
            'campaign_id', 'campaign_name', 'channel', 'channel_category',
            'emails_sent', 'emails_opened', 'emails_clicked', 'conversions', 'unique_recipients',
            'open_rate', 'click_rate', 'conversion_rate', 'attributed_revenue',
            'revenue_per_conversion',
            # Peer comparison columns (partitioned by channel_category)
            'category_conversion_rank', 'category_campaign_count',
            'above_category_avg_conversion', 'category_revenue_percentile',
            # Composite score and tier
            'performance_index', 'campaign_tier'
        ]

        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM rpt_campaign_performance LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute(f"""
                SELECT * FROM {prefix}rpt_campaign_performance LIMIT 1
            """)
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Tier Values ============

def component_5_valid_tier_values():
    """campaign_tier must only contain valid tier names."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        result = execute_query(conn, db_type, f"""
            SELECT DISTINCT campaign_tier FROM {prefix}rpt_campaign_performance
        """)

        valid_tiers = {'top_performer', 'effective', 'developing', 'underperforming', 'ineffective'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid tier values found: {invalid}")
        return 1.0
    finally:
        conn.close()




# ============ COMPONENT 7: Peer Metrics Partitioned by channel_category ============

def component_7_peer_metrics_partitioned():
    """Peer metrics must be partitioned by channel_category - each category should have rank 1."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        # Check that each channel_category has a campaign with rank 1
        result = execute_query(conn, db_type, f"""
            SELECT channel_category, MIN(category_conversion_rank) as min_rank
            FROM {prefix}rpt_campaign_performance
            GROUP BY channel_category
        """)

        for cat, min_rank in result:
            require(min_rank == 1,
                    f"Channel category '{cat}' has min rank={min_rank}, should be 1. "
                    f"Window function not partitioned by channel_category correctly.")

        # Check category_campaign_count matches actual count per category
        count_check = execute_query(conn, db_type, f"""
            SELECT channel_category, category_campaign_count, COUNT(*) as actual_count
            FROM {prefix}rpt_campaign_performance
            GROUP BY channel_category, category_campaign_count
            HAVING category_campaign_count != COUNT(*)
        """)

        require(len(count_check) == 0,
                f"category_campaign_count mismatch: {count_check}")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: Uses DENSE_RANK for Ranking ============

def component_8_uses_dense_rank():
    """Must use DENSE_RANK() for category_conversion_rank."""
    sql = read_model_file().lower()

    has_dense_rank = 'dense_rank()' in sql or 'dense_rank ()' in sql

    require(has_dense_rank,
            "Must use DENSE_RANK() window function for category_conversion_rank")
    return 1.0


# ============ COMPONENT 9: Uses PERCENT_RANK for Percentile ============

def component_9_uses_percent_rank():
    """Must use PERCENT_RANK() for category_revenue_percentile."""
    sql = read_model_file().lower()

    has_percent_rank = 'percent_rank()' in sql or 'percent_rank ()' in sql

    require(has_percent_rank,
            "Must use PERCENT_RANK() window function for category_revenue_percentile")
    return 1.0


# ============ COMPONENT 10: Above Category Avg Conversion ============

def component_10_above_category_avg():
    """above_category_avg_conversion must be correctly calculated."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        mismatches = execute_query(conn, db_type, f"""
            WITH category_avgs AS (
                SELECT channel_category, AVG(conversion_rate) as avg_cr
                FROM {prefix}rpt_campaign_performance
                GROUP BY channel_category
            )
            SELECT r.campaign_id, r.conversion_rate, ca.avg_cr, r.above_category_avg_conversion,
                   CASE WHEN r.conversion_rate > ca.avg_cr THEN 1 ELSE 0 END as expected
            FROM {prefix}rpt_campaign_performance r
            JOIN category_avgs ca ON r.channel_category = ca.channel_category
            WHERE r.above_category_avg_conversion != (CASE WHEN r.conversion_rate > ca.avg_cr THEN 1 ELSE 0 END)
        """)

        require(len(mismatches) == 0,
                f"above_category_avg_conversion mismatches: {mismatches[:5]}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Performance Index Validation ============

def component_11_performance_index():
    """performance_index must be bounded 0-100 and follow expected formula."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        # Check bounds
        bounds = execute_query(conn, db_type, f"""
            SELECT MIN(performance_index), MAX(performance_index)
            FROM {prefix}rpt_campaign_performance
        """)

        min_pi, max_pi = bounds[0]
        if min_pi is not None:
            require(float(min_pi) >= 0, f"performance_index has value below 0: {min_pi}")
        if max_pi is not None:
            require(float(max_pi) <= 100.01, f"performance_index exceeds 100: {max_pi}")

        # Validate formula
        results = execute_query(conn, db_type, f"""
            SELECT
                campaign_id,
                open_rate,
                click_rate,
                conversion_rate,
                attributed_revenue,
                performance_index
            FROM {prefix}rpt_campaign_performance
            WHERE performance_index IS NOT NULL
        """)

        # Get campaign days from source
        campaign_days = {}
        days_data = execute_query(conn, db_type, f"""
            SELECT campaign_id, GREATEST(1, DATEDIFF('day', start_date, end_date)) as days
            FROM {prefix}stg_marketing__campaigns
        """)
        for cid, days in days_data:
            campaign_days[cid] = days

        for cid, or_val, cr_val, cvr_val, rev, actual_pi in results:
            or_val = float(or_val or 0)
            cr_val = float(cr_val or 0)
            cvr_val = float(cvr_val or 0)
            rev = float(rev or 0)
            actual_pi = float(actual_pi)
            days = float(campaign_days.get(cid, 1))

            rev_efficiency = min(rev / days / 1000.0, 1.0)
            expected_pi = (or_val * 0.25 + cr_val * 0.25 + cvr_val * 0.30 + rev_efficiency * 0.20) * 100
            expected_pi = min(100, max(0, expected_pi))

            require(abs(actual_pi - expected_pi) < 1.0,
                    f"Campaign {cid}: performance_index={actual_pi}, expected={expected_pi:.2f} "
                    f"(or={or_val:.3f}, cr={cr_val:.3f}, cvr={cvr_val:.3f}, rev_eff={rev_efficiency:.3f})")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Waterfall Tier Logic ============

def component_12_waterfall_tier_logic():
    """campaign_tier must follow strict waterfall logic based on channel_category."""
    conn, db_type = get_db_connection()
    prefix = get_schema_prefix()
    try:
        results = execute_query(conn, db_type, f"""
            WITH category_stats AS (
                SELECT
                    channel_category,
                    AVG(conversion_rate) as avg_cr
                FROM {prefix}rpt_campaign_performance
                GROUP BY channel_category
            ),
            perf_percentiles AS (
                SELECT
                    r.campaign_id,
                    r.channel_category,
                    PERCENT_RANK() OVER (PARTITION BY r.channel_category ORDER BY r.performance_index) as perf_pct
                FROM {prefix}rpt_campaign_performance r
            )
            SELECT
                r.campaign_id,
                r.conversions,
                r.conversion_rate,
                r.click_rate,
                r.performance_index,
                r.above_category_avg_conversion,
                r.campaign_tier,
                cs.avg_cr as category_avg,
                pp.perf_pct
            FROM {prefix}rpt_campaign_performance r
            JOIN category_stats cs ON r.channel_category = cs.channel_category
            JOIN perf_percentiles pp ON r.campaign_id = pp.campaign_id
        """)

        errors = []
        for row in results:
            cid, convs, cvr, cr, pi, above_avg, actual_tier, cat_avg, perf_pct = row
            cvr = float(cvr or 0)
            cr = float(cr or 0)
            pi = float(pi or 0)
            above_avg = int(above_avg or 0)
            perf_pct = float(perf_pct)

            # Waterfall logic (check worst first)
            if convs == 0:
                expected = 'ineffective'
            elif above_avg == 0 and cr < 0.20:
                expected = 'underperforming'
            elif above_avg == 0 or cr < 0.40:
                expected = 'developing'
            elif perf_pct >= 0.80 and cvr > 0.10:
                expected = 'top_performer'
            elif above_avg == 1 and pi >= 50:
                expected = 'effective'
            else:
                expected = 'developing'

            if actual_tier.lower() != expected:
                errors.append(f"Campaign {cid}: tier='{actual_tier}', expected='{expected}' "
                              f"(convs={convs}, cvr={cvr:.3f}, cr={cr:.3f}, pi={pi:.1f}, "
                              f"above_avg={above_avg}, perf_pct={perf_pct:.2f})")

        require(len(errors) == 0, f"Tier mismatches:\n" + "\n".join(errors[:5]))
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
    "component_7_peer_metrics_partitioned": 1.0,
    "component_8_uses_dense_rank": 1.0,
    "component_9_uses_percent_rank": 1.0,
    "component_10_above_category_avg": 1.0,
    "component_11_performance_index": 1.0,
    "component_12_waterfall_tier_logic": 1.0,
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
