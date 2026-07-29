"""
Test verifier for dbt-fix-refund-reconciliation task.
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
        # Try password auth first (many Snowflake accounts use password, not private key)
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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def read_model_file():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        model_path = "/app/dbt_models_snowflake/models/marts/sales/rpt_return_reconciliation.sql"
    else:
        model_path = f"{get_dbt_project_dir()}/models/marts/sales/rpt_return_reconciliation.sql"
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

    result = run_cmd("dbt run -s rpt_return_reconciliation")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")
    return 1.0


# ============ COMPONENT 2: No inf/nan Values ============

def component_2_no_inf_nan_values():
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                days_to_receive, days_to_process, total_processing_days,
                refund_completion_rate, processing_efficiency
            FROM main.rpt_return_reconciliation
        """)

        inf_nan_count = 0
        for row in rows:
            for val in row:
                try:
                    if val is not None and (math.isinf(float(val)) or math.isnan(float(val))):
                        inf_nan_count += 1
                except (TypeError, ValueError, OverflowError):
                    pass

        require(inf_nan_count == 0, f"Found {inf_nan_count} inf/nan values - division not handled")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 3: Row Count ============

def component_3_row_count():
    conn, db_type = get_db_connection()
    try:
        output_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) FROM main.rpt_return_reconciliation
        """)

        source_count = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM main.stg_orders__returns
            WHERE return_id IS NOT NULL
        """)

        require(output_count == source_count,
                f"Row count mismatch: output={output_count}, expected={source_count} - check WHERE clause")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 4: Required Columns ============

def component_4_required_columns():
    conn, db_type = get_db_connection()
    try:
        required_columns = [
            'return_id', 'return_number', 'order_id', 'customer_id',
            'return_type', 'refund_method', 'status', 'total_return_amount',
            'total_refund_amount', 'return_line_count', 'requested_at',
            'received_at', 'processed_at', 'days_to_receive', 'days_to_process',
            'total_processing_days', 'refund_completion_rate', 'processing_efficiency',
            'refund_velocity_tier'
        ]

        rows = execute_query(conn, db_type, "SELECT * FROM main.rpt_return_reconciliation LIMIT 1")
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM main.rpt_return_reconciliation LIMIT 1")
            actual_columns = [col[0].lower() for col in cursor.description]
        else:
            result = conn.execute("SELECT * FROM main.rpt_return_reconciliation LIMIT 1")
            actual_columns = [col[0].lower() for col in result.description]

        missing = [col for col in required_columns if col.lower() not in actual_columns]
        require(len(missing) == 0, f"Missing columns: {missing}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 5: Valid Tier Values ============

def component_5_valid_tier_values():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT DISTINCT refund_velocity_tier FROM main.rpt_return_reconciliation
        """)

        valid_tiers = {'critical_delay', 'needs_improvement', 'acceptable', 'efficient'}
        actual_tiers = {row[0].lower() if row[0] else None for row in result}

        invalid = actual_tiers - valid_tiers - {None}
        require(len(invalid) == 0, f"Invalid tier values: {invalid}")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 6: Uses Window Function ============

def component_6_uses_window_function():
    sql = read_model_file().lower()
    has_window = 'percent_rank()' in sql or 'ntile(' in sql
    require(has_window, "Must use PERCENT_RANK() or NTILE() for percentile classification")
    return 1.0


# ============ COMPONENT 7: Tier Distribution ============

def component_7_tier_distribution():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT refund_velocity_tier, COUNT(*) as cnt
            FROM main.rpt_return_reconciliation
            GROUP BY refund_velocity_tier
        """)

        tier_counts = {row[0].lower() if row[0] else None: row[1] for row in result}
        require(len(tier_counts) >= 2, f"Only {len(tier_counts)} distinct tiers")
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 8: Waterfall Tier Logic ============

def component_8_waterfall_tier_logic():
    conn, db_type = get_db_connection()
    try:
        results = execute_query(conn, db_type, """
            WITH processing_pct AS (
                SELECT
                    return_id,
                    PERCENT_RANK() OVER (ORDER BY total_processing_days DESC) as slow_pct
                FROM main.rpt_return_reconciliation
                WHERE total_processing_days IS NOT NULL
            )
            SELECT
                r.return_id,
                r.total_processing_days,
                r.refund_completion_rate,
                r.refund_velocity_tier,
                COALESCE(p.slow_pct, 0.60) as slow_percentile
            FROM main.rpt_return_reconciliation r
            LEFT JOIN processing_pct p ON r.return_id = p.return_id
            ORDER BY r.return_id
            LIMIT 50
        """)

        errors = []
        for rid, proc_days, compl_rate, actual_tier, slow_pct in results:
            proc_days = proc_days if proc_days is not None else 999
            compl_rate = compl_rate or 0

            # Waterfall logic (slowest processors have LOWEST percentile when sorted DESC)
            if slow_pct <= 0.25 and proc_days > 10:
                expected = 'critical_delay'
            elif slow_pct <= 0.50 or compl_rate < 0.80:
                expected = 'needs_improvement'
            elif compl_rate >= 0.85 and proc_days <= 7:
                expected = 'acceptable'
            elif slow_pct >= 0.75 and compl_rate >= 0.90:
                expected = 'efficient'
            else:
                expected = 'acceptable'

            if actual_tier and actual_tier.lower() != expected:
                errors.append(f"return {rid}: tier='{actual_tier}', expected='{expected}' "
                            f"(days={proc_days:.1f}, rate={compl_rate:.2f}, slow_pct={slow_pct:.2f})")

        require(len(errors) == 0, f"Tier logic errors:\n" + "\n".join(errors[:5]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 9: Refund Completion Rate Formula Validation ============

def component_9_refund_completion_rate_formula():
    """Verify refund_completion_rate = total_refund_amount / total_return_amount * 100
    for sampled rows, and that zero total_return_amount does not produce infinity/NaN."""
    conn, db_type = get_db_connection()
    try:
        # Check that rows with total_return_amount = 0 do not have inf/NaN completion rate
        zero_amount_rows = execute_query(conn, db_type, """
            SELECT return_id, total_return_amount, total_refund_amount, refund_completion_rate
            FROM main.rpt_return_reconciliation
            WHERE total_return_amount = 0 OR total_return_amount IS NULL
        """)
        for row in zero_amount_rows:
            rid, ret_amt, ref_amt, rate = row
            if rate is not None:
                rate_f = float(rate)
                require(not math.isinf(rate_f),
                        f"return {rid}: refund_completion_rate is infinity when total_return_amount={ret_amt}")
                require(not math.isnan(rate_f),
                        f"return {rid}: refund_completion_rate is NaN when total_return_amount={ret_amt}")

        # Validate formula on rows where total_return_amount > 0
        sample_rows = execute_query(conn, db_type, """
            SELECT return_id, total_return_amount, total_refund_amount, refund_completion_rate
            FROM main.rpt_return_reconciliation
            WHERE total_return_amount > 0
              AND refund_completion_rate IS NOT NULL
            ORDER BY return_id
            LIMIT 50
        """)
        require(len(sample_rows) > 0, "No rows with total_return_amount > 0 found to validate formula")

        errors = []
        for row in sample_rows:
            rid, ret_amt, ref_amt, actual_rate = row
            ret_amt_f = float(ret_amt)
            ref_amt_f = float(ref_amt) if ref_amt is not None else 0.0
            actual_rate_f = float(actual_rate)

            # The model may store the rate as a ratio (0-1) or as a percentage (0-100).
            # Check both interpretations; accept whichever is within tolerance.
            expected_ratio = ref_amt_f / ret_amt_f
            expected_pct = expected_ratio * 100.0

            ratio_close = abs(actual_rate_f - expected_ratio) < 0.01
            pct_close = abs(actual_rate_f - expected_pct) < 1.0

            if not ratio_close and not pct_close:
                errors.append(
                    f"return {rid}: refund_completion_rate={actual_rate_f:.4f}, "
                    f"expected ratio={expected_ratio:.4f} or pct={expected_pct:.2f} "
                    f"(refund={ref_amt_f}, return={ret_amt_f})"
                )

        require(len(errors) == 0,
                f"Refund completion rate formula mismatches:\n" + "\n".join(errors[:10]))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 10: No Infinity/NaN in Any Numeric Column (SQL-level) ============

def component_10_no_inf_nan_all_numeric_columns():
    """Use SQL CASE WHEN to check that no numeric column contains infinity or NaN values.
    This is a more comprehensive check than component_2 which only checks 5 columns."""
    conn, db_type = get_db_connection()
    try:
        numeric_cols = [
            'total_return_amount', 'total_refund_amount', 'return_line_count',
            'days_to_receive', 'days_to_process', 'total_processing_days',
            'refund_completion_rate', 'processing_efficiency'
        ]

        # Build SQL CASE WHEN checks for each column.
        # DuckDB supports isnan() and isinf(); Snowflake doesn't have those but
        # we can use CAST + string comparison or TRY_TO_DOUBLE patterns.
        # A portable approach: CAST to VARCHAR and check for 'inf', '-inf', 'nan', 'NaN', 'Infinity'.
        checks = []
        for col in numeric_cols:
            checks.append(
                f"SUM(CASE WHEN CAST({col} AS VARCHAR) IN "
                f"('inf', '-inf', 'nan', 'NaN', 'Infinity', '-Infinity', 'infinity', '-infinity') "
                f"THEN 1 ELSE 0 END) AS {col}_bad"
            )

        query = f"SELECT {', '.join(checks)} FROM main.rpt_return_reconciliation"
        result = execute_query(conn, db_type, query)

        if result:
            bad_cols = []
            for i, col in enumerate(numeric_cols):
                bad_count = int(result[0][i])
                if bad_count > 0:
                    bad_cols.append(f"{col}: {bad_count} inf/NaN values")
            require(len(bad_cols) == 0,
                    f"Infinity/NaN found in numeric columns: {'; '.join(bad_cols)}")

        # Also do a Python-side check by fetching the actual numeric values
        rows = execute_query(conn, db_type, f"""
            SELECT {', '.join(numeric_cols)}
            FROM main.rpt_return_reconciliation
        """)
        inf_nan_count = 0
        bad_details = []
        for row_idx, row in enumerate(rows):
            for col_idx, val in enumerate(row):
                if val is not None:
                    try:
                        fval = float(val)
                        if math.isinf(fval) or math.isnan(fval):
                            inf_nan_count += 1
                            if len(bad_details) < 5:
                                bad_details.append(
                                    f"row {row_idx}, {numeric_cols[col_idx]}={val}")
                    except (TypeError, ValueError):
                        pass

        require(inf_nan_count == 0,
                f"Found {inf_nan_count} inf/NaN values in numeric columns: "
                + "; ".join(bad_details))
        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 11: Boundary Testing for refund_velocity_tier ============

def component_11_tier_boundary_testing():
    """Verify tier column constraints:
    - Only valid values exist
    - At least 2 different tier values
    - NULLs in total_processing_days still get a valid tier
    """
    conn, db_type = get_db_connection()
    try:
        valid_tiers = {'critical_delay', 'needs_improvement', 'acceptable', 'efficient'}

        # 1. Only valid values
        distinct_tiers = execute_query(conn, db_type, """
            SELECT DISTINCT refund_velocity_tier
            FROM main.rpt_return_reconciliation
        """)
        actual_tiers = set()
        for row in distinct_tiers:
            tier_val = row[0]
            if tier_val is not None:
                actual_tiers.add(tier_val.lower())
        invalid = actual_tiers - valid_tiers
        require(len(invalid) == 0,
                f"Invalid refund_velocity_tier values found: {invalid}")

        # 2. At least 2 different tier values exist
        require(len(actual_tiers) >= 2,
                f"Only {len(actual_tiers)} distinct tier(s) found ({actual_tiers}); "
                f"expected at least 2 different tiers for meaningful classification")

        # 3. NULL total_processing_days should still get a valid (non-NULL) tier
        null_proc_rows = execute_query(conn, db_type, """
            SELECT return_id, refund_velocity_tier
            FROM main.rpt_return_reconciliation
            WHERE total_processing_days IS NULL
        """)
        null_tier_count = 0
        invalid_tier_for_null = []
        for row in null_proc_rows:
            rid, tier = row
            if tier is None:
                null_tier_count += 1
                if len(invalid_tier_for_null) < 5:
                    invalid_tier_for_null.append(str(rid))
            elif tier.lower() not in valid_tiers:
                invalid_tier_for_null.append(
                    f"{rid} (invalid tier: {tier})")

        require(null_tier_count == 0,
                f"Found {null_tier_count} rows with NULL total_processing_days that have "
                f"NULL refund_velocity_tier (should still be classified). "
                f"Sample return_ids: {', '.join(invalid_tier_for_null[:5])}")
        require(len(invalid_tier_for_null) == 0,
                f"Rows with NULL total_processing_days have invalid tiers: "
                + ", ".join(invalid_tier_for_null[:5]))

        # 4. No row at all should have NULL tier (every return needs a classification)
        null_tier_total = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM main.rpt_return_reconciliation
            WHERE refund_velocity_tier IS NULL
        """)
        require(int(null_tier_total) == 0,
                f"Found {null_tier_total} rows with NULL refund_velocity_tier; "
                f"every return must be classified")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 12: Days Non-Negative ============

def component_12_days_non_negative():
    """Verify days_to_receive and days_to_process are >= 0 where not NULL."""
    conn, db_type = get_db_connection()
    try:
        negative_receive = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM main.rpt_return_reconciliation
            WHERE days_to_receive < 0
        """)
        require(int(negative_receive) == 0,
                f"Found {negative_receive} rows with negative days_to_receive. "
                f"A return cannot be received before it was requested.")

        negative_process = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM main.rpt_return_reconciliation
            WHERE days_to_process < 0
        """)
        require(int(negative_process) == 0,
                f"Found {negative_process} rows with negative days_to_process. "
                f"A return cannot be processed before it was received.")

        # Also check total_processing_days non-negative
        negative_total = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM main.rpt_return_reconciliation
            WHERE total_processing_days < 0
        """)
        require(int(negative_total) == 0,
                f"Found {negative_total} rows with negative total_processing_days.")

        return 1.0
    finally:
        conn.close()


# ============ COMPONENT 13: Total Processing Days Consistency ============

def component_13_total_processing_days_consistency():
    """Verify total_processing_days = days_to_receive + days_to_process
    where both component values are not NULL."""
    conn, db_type = get_db_connection()
    try:
        inconsistent = execute_query(conn, db_type, """
            SELECT
                return_id,
                days_to_receive,
                days_to_process,
                total_processing_days,
                days_to_receive + days_to_process AS expected_total
            FROM main.rpt_return_reconciliation
            WHERE days_to_receive IS NOT NULL
              AND days_to_process IS NOT NULL
              AND total_processing_days IS NOT NULL
              AND ABS(total_processing_days - (days_to_receive + days_to_process)) > 1
        """)

        if len(inconsistent) > 0:
            details = []
            for row in inconsistent[:10]:
                rid, recv, proc, total, expected = row
                details.append(
                    f"return {rid}: days_to_receive={recv} + days_to_process={proc} "
                    f"= {expected}, but total_processing_days={total}"
                )
            require(False,
                    f"Found {len(inconsistent)} rows where total_processing_days != "
                    f"days_to_receive + days_to_process (tolerance=1 day):\n"
                    + "\n".join(details))

        # Ensure there are actually rows to validate (not vacuously true)
        validatable = execute_scalar(conn, db_type, """
            SELECT COUNT(*)
            FROM main.rpt_return_reconciliation
            WHERE days_to_receive IS NOT NULL
              AND days_to_process IS NOT NULL
              AND total_processing_days IS NOT NULL
        """)
        require(int(validatable) > 0,
                "No rows found where all three day columns are non-NULL; "
                "cannot validate consistency")

        return 1.0
    finally:
        conn.close()


WEIGHTS = {
    "component_1_model_compiles": 1.0,
    "component_2_no_inf_nan_values": 1.0,
    "component_3_row_count": 1.0,
    "component_4_required_columns": 1.0,
    "component_5_valid_tier_values": 1.0,
    "component_6_uses_window_function": 1.0,
    "component_7_tier_distribution": 1.0,
    "component_8_waterfall_tier_logic": 1.0,
    "component_9_refund_completion_rate_formula": 1.0,
    "component_10_no_inf_nan_all_numeric_columns": 1.0,
    "component_11_tier_boundary_testing": 1.0,
    "component_12_days_non_negative": 1.0,
    "component_13_total_processing_days_consistency": 1.0,
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
