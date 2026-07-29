"""
Verifier for Multi-Touch Attribution Fix task.
Validates schema, data quality, five attribution models, channel_group, assist_sessions,
and reconciliation against expected logic. Uses a fixed 91-day window (2025-10-02 to 2025-12-31).
Supports both DuckDB and Snowflake backends.
"""
import os
import re
import subprocess
import json
from pathlib import Path

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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def run_cmd(cmd, cwd=None):
    """Execute a shell command and return the result. Print stdout/stderr on failure."""
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:800]}")
    return result


def require(cond, msg):
    """Assert condition; raise AssertionError with msg if false."""
    if not cond:
        raise AssertionError(msg)


def _use_joined_revenue(conn, db_type):
    """Return True if main.int_sessions_events_joined exists and has t2_event_value."""
    try:
        execute_query(conn, db_type, "SELECT t2_event_value FROM main.int_sessions_events_joined LIMIT 1")
        return True
    except Exception:
        return False


def _conversion_revenue_cte(conn, db_type):
    """Return the conversion_revenue CTE SQL fragment matching the model's preferred source."""
    if _use_joined_revenue(conn, db_type):
        if db_type == 'snowflake':
            return """
        conversion_revenue AS (
            SELECT j.session_id, ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM main.int_sessions_events_joined j
            JOIN main.stg_ga__sessions s ON j.session_id = s.session_id
            WHERE UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')
              AND CAST(s.session_start AS DATE) BETWEEN '2025-10-02' AND '2025-12-31'
              AND j.t2_event_name = 'purchase' AND j.t2_event_value IS NOT NULL
            GROUP BY j.session_id
        )"""
        else:
            return """
        conversion_revenue AS (
            SELECT j.session_id, ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM main.int_sessions_events_joined j
            JOIN main.stg_ga__sessions s ON j.session_id = s.session_id
            WHERE s.is_converted = true AND CAST(s.session_start AS DATE) BETWEEN '2025-10-02'::DATE AND '2025-12-31'::DATE
              AND j.t2_event_name = 'purchase' AND j.t2_event_value IS NOT NULL
            GROUP BY j.session_id
        )"""
    if db_type == 'snowflake':
        return """
        conversion_revenue AS (
            SELECT e.session_id, ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM main.stg_ga__events e
            JOIN main.stg_ga__sessions s ON e.session_id = s.session_id
            WHERE UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')
              AND CAST(s.session_start AS DATE) BETWEEN '2025-10-02' AND '2025-12-31'
              AND e.event_name = 'purchase' AND e.event_value IS NOT NULL
            GROUP BY e.session_id
        )"""
    return """
        conversion_revenue AS (
            SELECT e.session_id, ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM main.stg_ga__events e
            JOIN main.stg_ga__sessions s ON e.session_id = s.session_id
            WHERE s.is_converted = true AND CAST(s.session_start AS DATE) BETWEEN '2025-10-02'::DATE AND '2025-12-31'::DATE
              AND e.event_name = 'purchase' AND e.event_value IS NOT NULL
            GROUP BY e.session_id
        )"""


def _is_converted_condition(db_type, alias='s'):
    """Return the is_converted condition based on db_type."""
    if db_type == 'snowflake':
        return f"UPPER(CAST({alias}.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')"
    return f"{alias}.is_converted = true"


def _date_between(db_type):
    """Return the date between condition based on db_type."""
    if db_type == 'snowflake':
        return "BETWEEN '2025-10-02' AND '2025-12-31'"
    return "BETWEEN '2025-10-02'::DATE AND '2025-12-31'::DATE"


def _date_diff_days(db_type, start_expr, end_expr):
    """Return date difference in days expression."""
    if db_type == 'snowflake':
        return f"DATEDIFF('day', {start_expr}, {end_expr})"
    return f"({end_expr} - {start_expr})"


def run_dbt_pipeline(db_type):
    """Build reference models, drop existing report table, and run rpt_multi_touch_attribution_fixed."""
    ref_project_dir = get_dbt_project_dir()
    run_cmd("dbt deps", cwd=ref_project_dir)
    run_cmd(
        "dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined",
        cwd=ref_project_dir,
    )

    if db_type == 'duckdb':
        import duckdb
        conn = duckdb.connect("/app/database/retail.duckdb")
        for name in [
            "analytics.rpt_multi_touch_attribution_fixed",
            "ANALYTICS.rpt_multi_touch_attribution_fixed",
            "rpt_multi_touch_attribution_fixed",
        ]:
            try:
                conn.execute(f"DROP TABLE IF EXISTS {name}")
            except Exception:
                pass
        conn.close()

    res = run_cmd("dbt run --select rpt_multi_touch_attribution_fixed --full-refresh", cwd="/app/dbt_project")
    if res.returncode != 0:
        err = res.stderr or res.stdout
        require(False, f"dbt run failed: {err[:1500]}")


def _get_report_table(db_type):
    """Return the fully qualified report table reference."""
    return "analytics.rpt_multi_touch_attribution_fixed"


# ============ TEST COMPONENTS ============


def component_1_structure():
    """Smoke test: required model file exists at the expected path."""
    require(
        os.path.exists("/app/dbt_project/models/marts/marketing/rpt_multi_touch_attribution_fixed.sql"),
        "rpt_multi_touch_attribution_fixed.sql model missing",
    )
    return 1.0


def component_2_dbt_pipeline():
    """Validate project structure, run dbt pipeline."""
    require(os.path.exists("/app/dbt_project"), "dbt_project directory missing - agent must create /app/dbt_project")
    require(
        os.path.exists("/app/dbt_project/models/marts/marketing/rpt_multi_touch_attribution_fixed.sql"),
        "Model missing: /app/dbt_project/models/marts/marketing/rpt_multi_touch_attribution_fixed.sql",
    )
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    run_dbt_pipeline(db_type)
    return 1.0


def component_3_schema():
    """
    Verify the output table has all required columns and correct types.
    """
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        if db_type == 'snowflake':
            cols = execute_query(conn, db_type,
                f"SELECT lower(column_name), lower(data_type) FROM information_schema.columns WHERE lower(table_schema) = 'analytics' AND lower(table_name) = 'rpt_multi_touch_attribution_fixed'")
        else:
            cols = execute_query(conn, db_type,
                f"SELECT name, type FROM pragma_table_info('{report_table}') ORDER BY cid")
            cols = [(c[0].lower(), c[1].lower()) for c in cols]

        col_names = {c[0] for c in cols}
        required = {
            "attribution_date", "channel", "medium", "campaign", "channel_group",
            "attribution_model", "sessions", "conversions", "attributed_revenue",
            "conversion_rate", "assist_sessions",
        }
        missing = required - col_names
        require(not missing, f"Missing required columns: {missing}")

        col_dict = {c[0]: c[1] for c in cols}

        if db_type == 'duckdb':
            require("date" in col_dict.get("attribution_date", ""), "attribution_date must be DATE type")
            require("integer" in col_dict.get("sessions", "") or "bigint" in col_dict.get("sessions", ""), "sessions must be INTEGER type")
            require("integer" in col_dict.get("conversions", "") or "bigint" in col_dict.get("conversions", ""), "conversions must be INTEGER type")
            require("integer" in col_dict.get("assist_sessions", "") or "bigint" in col_dict.get("assist_sessions", ""), "assist_sessions must be INTEGER type")
        else:
            require("date" in col_dict.get("attribution_date", ""), "attribution_date must be DATE type")
            require("number" in col_dict.get("sessions", "") or "int" in col_dict.get("sessions", ""), "sessions must be NUMBER/INTEGER type")
            require("number" in col_dict.get("conversions", "") or "int" in col_dict.get("conversions", ""), "conversions must be NUMBER/INTEGER type")
            require("number" in col_dict.get("assist_sessions", "") or "int" in col_dict.get("assist_sessions", ""), "assist_sessions must be NUMBER/INTEGER type")
        return 1.0
    finally:
        conn.close()


def component_4_data_quality():
    """
    Assert no nulls in required columns, conversion_rate in [0,1], conversions <= sessions,
    channel_group in allowed set, revenue/rate precision, no negative values.
    """
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        null_check = execute_query(conn, db_type, f"""
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN attribution_date IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN channel IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN medium IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN campaign IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN channel_group IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN attribution_model IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN sessions IS NULL OR conversions IS NULL OR attributed_revenue IS NULL OR conversion_rate IS NULL OR assist_sessions IS NULL THEN 1 ELSE 0 END)
            FROM {report_table}
        """)
        row = null_check[0]
        require(int(row[1]) == 0, "NULL attribution_date")
        require(int(row[2]) == 0, "NULL channel")
        require(int(row[3]) == 0, "NULL medium")
        require(int(row[4]) == 0, "NULL campaign")
        require(int(row[5]) == 0, "NULL channel_group")
        require(int(row[6]) == 0, "NULL attribution_model")
        require(int(row[7]) == 0, "NULL in sessions/conversions/attributed_revenue/conversion_rate/assist_sessions")

        invalid_rates = int(execute_scalar(conn, db_type,
            f"SELECT COUNT(*) FROM {report_table} WHERE conversion_rate < 0 OR conversion_rate > 1"))
        require(invalid_rates == 0, f"Rows with conversion_rate not in [0,1]: {invalid_rates}")

        invalid_counts = int(execute_scalar(conn, db_type,
            f"SELECT COUNT(*) FROM {report_table} WHERE conversions > sessions"))
        require(invalid_counts == 0, f"Rows where conversions > sessions: {invalid_counts}")

        invalid_cg = int(execute_scalar(conn, db_type,
            f"SELECT COUNT(*) FROM {report_table} WHERE channel_group NOT IN ('Direct','Paid','Organic','Referral')"))
        require(invalid_cg == 0, f"Rows with invalid channel_group: {invalid_cg}")

        bad_revenue = int(execute_scalar(conn, db_type,
            f"SELECT COUNT(*) FROM {report_table} WHERE attributed_revenue IS NOT NULL AND attributed_revenue != ROUND(attributed_revenue, 2)"))
        require(bad_revenue == 0, f"attributed_revenue not rounded to 2 decimals: {bad_revenue}")

        bad_rate = int(execute_scalar(conn, db_type,
            f"SELECT COUNT(*) FROM {report_table} WHERE conversion_rate IS NOT NULL AND conversion_rate != ROUND(conversion_rate, 4)"))
        require(bad_rate == 0, f"conversion_rate not rounded to 4 decimals: {bad_rate}")

        negative = int(execute_scalar(conn, db_type,
            f"SELECT COUNT(*) FROM {report_table} WHERE sessions < 0 OR conversions < 0 OR attributed_revenue < 0 OR assist_sessions < 0"))
        require(negative == 0, f"Negative values: {negative}")
        return 1.0
    finally:
        conn.close()


def component_5_model_presence():
    """Ensure all five attribution_model values appear. If no data, skip."""
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        models = [r[0] for r in execute_query(conn, db_type,
            f"SELECT DISTINCT attribution_model FROM {report_table}")]
        if not models:
            n = int(execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {report_table}"))
            require(n == 0, "Table has rows but no attribution_model values")
            return 1.0
        for m in ["last_touch", "first_touch", "linear", "time_decay", "position_based"]:
            require(m in models, f"Missing attribution_model: {m}")
        return 1.0
    finally:
        conn.close()


def component_6_last_touch_reconciliation():
    """Reconcile last_touch rows against expected query over sessions/events; require exact match."""
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        rev_cte = _conversion_revenue_cte(conn, db_type)
        is_conv = _is_converted_condition(db_type, 's')
        date_btwn = _date_between(db_type)

        if db_type == 'snowflake':
            is_conv_sb = "UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')"
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT DISTINCT
                        s.session_id,
                        CAST(s.session_start AS DATE) AS attribution_date,
                        COALESCE(s.utm_source, 'direct') AS channel,
                        COALESCE(s.utm_medium, 'none') AS medium,
                        COALESCE(s.utm_campaign, 'none') AS campaign,
                        CASE WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid'
                             WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
                             WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct') AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct'
                             ELSE 'Referral' END AS channel_group,
                        CASE WHEN {is_conv_sb} THEN TRUE ELSE FALSE END AS is_converted
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                ),
                {rev_cte}
                SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
                       COUNT(DISTINCT sb.session_id) AS sessions,
                       SUM(CASE WHEN sb.is_converted THEN 1 ELSE 0 END) AS conversions,
                       ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS attributed_revenue,
                       CASE WHEN COUNT(DISTINCT sb.session_id) > 0 THEN ROUND(CAST(SUM(CASE WHEN sb.is_converted THEN 1 ELSE 0 END) AS DECIMAL(18,8)) / CAST(COUNT(DISTINCT sb.session_id) AS DECIMAL(18,8)), 4) ELSE 0.0 END AS conversion_rate
                FROM sessions_base sb
                LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
                GROUP BY 1,2,3,4,5
            """)
        else:
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT DISTINCT
                        s.session_id,
                        CAST(s.session_start AS DATE) AS attribution_date,
                        COALESCE(s.utm_source, 'direct') AS channel,
                        COALESCE(s.utm_medium, 'none') AS medium,
                        COALESCE(s.utm_campaign, 'none') AS campaign,
                        CASE WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid'
                             WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
                             WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct') AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct'
                             ELSE 'Referral' END AS channel_group,
                        s.is_converted
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                ),
                {rev_cte}
                SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
                       CAST(COUNT(DISTINCT sb.session_id) AS BIGINT) AS sessions,
                       CAST(SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS BIGINT) AS conversions,
                       CAST(ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
                       CAST(CASE WHEN COUNT(DISTINCT sb.session_id) > 0 THEN ROUND(CAST(SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS DECIMAL(18,8)) / CAST(COUNT(DISTINCT sb.session_id) AS DECIMAL(18,8)), 4) ELSE 0.0 END AS DECIMAL(10,4)) AS conversion_rate
                FROM sessions_base sb
                LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
                GROUP BY 1,2,3,4,5
            """)

        if db_type == 'snowflake':
            actual = execute_query(conn, db_type, f"""
                SELECT attribution_date, channel, medium, campaign, channel_group,
                       sessions, conversions,
                       attributed_revenue, conversion_rate
                FROM {report_table} WHERE attribution_model = 'last_touch'
            """)
            # Compare with tolerance for Snowflake Decimal differences
            exp_map = {}
            for r in expected:
                key = (str(r[0]), r[1], r[2], r[3], r[4])
                exp_map[key] = (int(r[5]), int(r[6]), float(r[7]), float(r[8]))
            act_map = {}
            for r in actual:
                key = (str(r[0]), r[1], r[2], r[3], r[4])
                act_map[key] = (int(r[5]), int(r[6]), float(r[7]), float(r[8]))
            missing_keys = set(exp_map.keys()) - set(act_map.keys())
            extra_keys = set(act_map.keys()) - set(exp_map.keys())
            require(not missing_keys, f"last_touch: missing expected rows (sample: {list(missing_keys)[:3]})")
            require(not extra_keys, f"last_touch: extra rows (sample: {list(extra_keys)[:3]})")
            for key in exp_map:
                e = exp_map[key]
                a = act_map[key]
                require(e[0] == a[0], f"last_touch sessions mismatch for {key}: expected {e[0]}, got {a[0]}")
                require(e[1] == a[1], f"last_touch conversions mismatch for {key}: expected {e[1]}, got {a[1]}")
                require(abs(e[2] - a[2]) < 0.02, f"last_touch revenue mismatch for {key}: expected {e[2]}, got {a[2]}")
                require(abs(e[3] - a[3]) < 0.001, f"last_touch conv_rate mismatch for {key}: expected {e[3]}, got {a[3]}")
        else:
            actual = execute_query(conn, db_type, f"""
                SELECT attribution_date, channel, medium, campaign, channel_group,
                       CAST(sessions AS BIGINT), CAST(conversions AS BIGINT),
                       CAST(attributed_revenue AS DECIMAL(12,2)), CAST(conversion_rate AS DECIMAL(10,4))
                FROM {report_table} WHERE attribution_model = 'last_touch'
            """)
            exp_set = set(expected)
            act_set = set(actual)
            require(not (exp_set - act_set), f"last_touch: missing expected rows (sample: {list(exp_set - act_set)[:3]})")
            require(not (act_set - exp_set), f"last_touch: extra rows (sample: {list(act_set - exp_set)[:3]})")
        return 1.0
    finally:
        conn.close()


def component_7_first_touch_reconciliation():
    """Reconcile first_touch rows against expected logic (earliest session per visitor); exact match."""
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        rev_cte = _conversion_revenue_cte(conn, db_type)
        date_btwn = _date_between(db_type)

        if db_type == 'snowflake':
            is_conv_sb = "UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')"
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT DISTINCT s.session_id, COALESCE(s.visitor_id, s.session_id) AS visitor_id,
                        CAST(s.session_start AS DATE) AS attribution_date,
                        COALESCE(s.utm_source, 'direct') AS channel, COALESCE(s.utm_medium, 'none') AS medium, COALESCE(s.utm_campaign, 'none') AS campaign,
                        CASE WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid' WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
                             WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct') AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct' ELSE 'Referral' END AS channel_group,
                        CASE WHEN {is_conv_sb} THEN TRUE ELSE FALSE END AS is_converted, s.session_start
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                ),
                first_sessions AS (SELECT visitor_id, MIN(session_start) AS first_session_start FROM sessions_base GROUP BY visitor_id),
                user_totals AS (SELECT sb.visitor_id, COUNT(DISTINCT sb.session_id) AS total_sessions, SUM(CASE WHEN sb.is_converted THEN 1 ELSE 0 END) AS total_conversions FROM sessions_base sb GROUP BY sb.visitor_id),
                {rev_cte},
                user_revenue AS (
                    SELECT COALESCE(s.visitor_id, s.session_id) AS visitor_id, ROUND(SUM(COALESCE(cr.conversion_value, 0)), 2) AS total_revenue
                    FROM main.stg_ga__sessions s LEFT JOIN conversion_revenue cr ON s.session_id = cr.session_id
                    WHERE {is_conv_sb} AND CAST(s.session_start AS DATE) {date_btwn}
                    GROUP BY COALESCE(s.visitor_id, s.session_id)
                )
                SELECT CAST(fs.first_session_start AS DATE) AS attribution_date, sb_first.channel, sb_first.medium, sb_first.campaign, sb_first.channel_group,
                       SUM(ut.total_sessions) AS sessions, SUM(ut.total_conversions) AS conversions,
                       ROUND(COALESCE(SUM(ur.total_revenue), 0), 2) AS attributed_revenue,
                       CASE WHEN SUM(ut.total_sessions) > 0 THEN ROUND(CAST(SUM(ut.total_conversions) AS DECIMAL(18,8)) / CAST(SUM(ut.total_sessions) AS DECIMAL(18,8)), 4) ELSE 0.0 END AS conversion_rate
                FROM first_sessions fs
                JOIN sessions_base sb_first ON fs.visitor_id = sb_first.visitor_id AND fs.first_session_start = sb_first.session_start
                JOIN user_totals ut ON fs.visitor_id = ut.visitor_id
                LEFT JOIN user_revenue ur ON fs.visitor_id = ur.visitor_id
                GROUP BY 1,2,3,4,5
            """)
            actual = execute_query(conn, db_type, f"""
                SELECT attribution_date, channel, medium, campaign, channel_group,
                       sessions, conversions,
                       attributed_revenue, conversion_rate
                FROM {report_table} WHERE attribution_model = 'first_touch'
            """)
            exp_map = {}
            for r in expected:
                key = (str(r[0]), r[1], r[2], r[3], r[4])
                exp_map[key] = (int(r[5]), int(r[6]), float(r[7]), float(r[8]))
            act_map = {}
            for r in actual:
                key = (str(r[0]), r[1], r[2], r[3], r[4])
                act_map[key] = (int(r[5]), int(r[6]), float(r[7]), float(r[8]))
            missing_keys = set(exp_map.keys()) - set(act_map.keys())
            extra_keys = set(act_map.keys()) - set(exp_map.keys())
            require(not missing_keys, f"first_touch: missing expected rows (sample: {list(missing_keys)[:3]})")
            require(not extra_keys, f"first_touch: extra rows (sample: {list(extra_keys)[:3]})")
            for key in exp_map:
                e = exp_map[key]
                a = act_map[key]
                require(e[0] == a[0], f"first_touch sessions mismatch for {key}: expected {e[0]}, got {a[0]}")
                require(e[1] == a[1], f"first_touch conversions mismatch for {key}: expected {e[1]}, got {a[1]}")
                require(abs(e[2] - a[2]) < 0.02, f"first_touch revenue mismatch for {key}: expected {e[2]}, got {a[2]}")
                require(abs(e[3] - a[3]) < 0.001, f"first_touch conv_rate mismatch for {key}: expected {e[3]}, got {a[3]}")
        else:
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT DISTINCT s.session_id, COALESCE(s.visitor_id, s.session_id) AS visitor_id,
                        CAST(s.session_start AS DATE) AS attribution_date,
                        COALESCE(s.utm_source, 'direct') AS channel, COALESCE(s.utm_medium, 'none') AS medium, COALESCE(s.utm_campaign, 'none') AS campaign,
                        CASE WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid' WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
                             WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct') AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct' ELSE 'Referral' END AS channel_group,
                        s.is_converted, s.session_start
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                ),
                first_sessions AS (SELECT visitor_id, MIN(session_start) AS first_session_start FROM sessions_base GROUP BY visitor_id),
                user_totals AS (SELECT sb.visitor_id, COUNT(DISTINCT sb.session_id) AS total_sessions, SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS total_conversions FROM sessions_base sb GROUP BY sb.visitor_id),
                {rev_cte},
                user_revenue AS (
                    SELECT COALESCE(s.visitor_id, s.session_id) AS visitor_id, ROUND(SUM(COALESCE(cr.conversion_value, 0)), 2) AS total_revenue
                    FROM main.stg_ga__sessions s LEFT JOIN conversion_revenue cr ON s.session_id = cr.session_id
                    WHERE s.is_converted = true AND CAST(s.session_start AS DATE) {date_btwn}
                    GROUP BY COALESCE(s.visitor_id, s.session_id)
                )
                SELECT CAST(fs.first_session_start AS DATE) AS attribution_date, sb_first.channel, sb_first.medium, sb_first.campaign, sb_first.channel_group,
                       CAST(SUM(ut.total_sessions) AS BIGINT) AS sessions, CAST(SUM(ut.total_conversions) AS BIGINT) AS conversions,
                       CAST(ROUND(COALESCE(SUM(ur.total_revenue), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
                       CAST(CASE WHEN SUM(ut.total_sessions) > 0 THEN ROUND(CAST(SUM(ut.total_conversions) AS DECIMAL(18,8)) / CAST(SUM(ut.total_sessions) AS DECIMAL(18,8)), 4) ELSE 0.0 END AS DECIMAL(10,4)) AS conversion_rate
                FROM first_sessions fs
                JOIN sessions_base sb_first ON fs.visitor_id = sb_first.visitor_id AND fs.first_session_start = sb_first.session_start
                JOIN user_totals ut ON fs.visitor_id = ut.visitor_id
                LEFT JOIN user_revenue ur ON fs.visitor_id = ur.visitor_id
                GROUP BY 1,2,3,4,5
            """)
            actual = execute_query(conn, db_type, f"""
                SELECT attribution_date, channel, medium, campaign, channel_group,
                       CAST(sessions AS BIGINT), CAST(conversions AS BIGINT),
                       CAST(attributed_revenue AS DECIMAL(12,2)), CAST(conversion_rate AS DECIMAL(10,4))
                FROM {report_table} WHERE attribution_model = 'first_touch'
            """)
            exp_set = set(expected)
            act_set = set(actual)
            require(not (exp_set - act_set), f"first_touch: missing expected rows (sample: {list(exp_set - act_set)[:3]})")
            require(not (act_set - exp_set), f"first_touch: extra rows (sample: {list(act_set - exp_set)[:3]})")
        return 1.0
    finally:
        conn.close()


def component_8_linear_reconciliation():
    """Reconcile linear attribution against expected even-split logic; exact match."""
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        rev_cte = _conversion_revenue_cte(conn, db_type)
        date_btwn = _date_between(db_type)

        if db_type == 'snowflake':
            is_conv_sb = "UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')"
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT DISTINCT s.session_id, COALESCE(s.visitor_id, s.session_id) AS visitor_id,
                        CAST(s.session_start AS DATE) AS attribution_date,
                        COALESCE(s.utm_source, 'direct') AS channel, COALESCE(s.utm_medium, 'none') AS medium, COALESCE(s.utm_campaign, 'none') AS campaign,
                        CASE WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid' WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
                             WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct') AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct' ELSE 'Referral' END AS channel_group,
                        CASE WHEN {is_conv_sb} THEN TRUE ELSE FALSE END AS is_converted
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                ),
                session_counts AS (SELECT visitor_id, COUNT(DISTINCT session_id) AS session_count FROM sessions_base GROUP BY visitor_id),
                user_totals AS (SELECT sb.visitor_id, SUM(CASE WHEN sb.is_converted THEN 1 ELSE 0 END) AS total_conversions FROM sessions_base sb GROUP BY sb.visitor_id),
                {rev_cte},
                user_revenue AS (
                    SELECT COALESCE(s.visitor_id, s.session_id) AS visitor_id, ROUND(SUM(COALESCE(cr.conversion_value, 0)), 2) AS total_revenue
                    FROM main.stg_ga__sessions s LEFT JOIN conversion_revenue cr ON s.session_id = cr.session_id
                    WHERE {is_conv_sb} AND CAST(s.session_start AS DATE) {date_btwn}
                    GROUP BY COALESCE(s.visitor_id, s.session_id)
                ),
                linear_attribution AS (
                    SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
                           COUNT(DISTINCT sb.session_id) AS sessions,
                           ROUND(CAST(COALESCE(SUM(ut.total_conversions), 0) AS DECIMAL(18,8)) / NULLIF(MAX(sc.session_count), 0), 0) AS conversions,
                           ROUND(CAST(COALESCE(SUM(ur.total_revenue), 0) AS DECIMAL(18,8)) / NULLIF(MAX(sc.session_count), 0), 2) AS attributed_revenue
                    FROM sessions_base sb
                    JOIN session_counts sc ON sb.visitor_id = sc.visitor_id
                    LEFT JOIN user_totals ut ON sb.visitor_id = ut.visitor_id
                    LEFT JOIN user_revenue ur ON sb.visitor_id = ur.visitor_id
                    GROUP BY 1,2,3,4,5
                )
                SELECT attribution_date, channel, medium, campaign, channel_group, sessions, conversions, attributed_revenue,
                       CASE WHEN sessions > 0 THEN ROUND(CAST(conversions AS DECIMAL(18,8)) / CAST(sessions AS DECIMAL(18,8)), 4) ELSE 0.0 END AS conversion_rate
                FROM linear_attribution
            """)
            actual = execute_query(conn, db_type, f"""
                SELECT attribution_date, channel, medium, campaign, channel_group,
                       sessions, conversions,
                       attributed_revenue, conversion_rate
                FROM {report_table} WHERE attribution_model = 'linear'
            """)
            exp_map = {}
            for r in expected:
                key = (str(r[0]), r[1], r[2], r[3], r[4])
                exp_map[key] = (int(r[5]), int(r[6]), float(r[7]), float(r[8]))
            act_map = {}
            for r in actual:
                key = (str(r[0]), r[1], r[2], r[3], r[4])
                act_map[key] = (int(r[5]), int(r[6]), float(r[7]), float(r[8]))
            missing_keys = set(exp_map.keys()) - set(act_map.keys())
            extra_keys = set(act_map.keys()) - set(exp_map.keys())
            require(not missing_keys, f"linear: missing expected rows (sample: {list(missing_keys)[:3]})")
            require(not extra_keys, f"linear: extra rows (sample: {list(extra_keys)[:3]})")
            for key in exp_map:
                e = exp_map[key]
                a = act_map[key]
                require(e[0] == a[0], f"linear sessions mismatch for {key}: expected {e[0]}, got {a[0]}")
                require(e[1] == a[1], f"linear conversions mismatch for {key}: expected {e[1]}, got {a[1]}")
                require(abs(e[2] - a[2]) < 0.02, f"linear revenue mismatch for {key}: expected {e[2]}, got {a[2]}")
                require(abs(e[3] - a[3]) < 0.001, f"linear conv_rate mismatch for {key}: expected {e[3]}, got {a[3]}")
        else:
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT DISTINCT s.session_id, COALESCE(s.visitor_id, s.session_id) AS visitor_id,
                        CAST(s.session_start AS DATE) AS attribution_date,
                        COALESCE(s.utm_source, 'direct') AS channel, COALESCE(s.utm_medium, 'none') AS medium, COALESCE(s.utm_campaign, 'none') AS campaign,
                        CASE WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid' WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
                             WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct') AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct' ELSE 'Referral' END AS channel_group,
                        s.is_converted
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                ),
                session_counts AS (SELECT visitor_id, COUNT(DISTINCT session_id) AS session_count FROM sessions_base GROUP BY visitor_id),
                user_totals AS (SELECT sb.visitor_id, SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS total_conversions FROM sessions_base sb GROUP BY sb.visitor_id),
                {rev_cte},
                user_revenue AS (
                    SELECT COALESCE(s.visitor_id, s.session_id) AS visitor_id, ROUND(SUM(COALESCE(cr.conversion_value, 0)), 2) AS total_revenue
                    FROM main.stg_ga__sessions s LEFT JOIN conversion_revenue cr ON s.session_id = cr.session_id
                    WHERE s.is_converted = true AND CAST(s.session_start AS DATE) {date_btwn}
                    GROUP BY COALESCE(s.visitor_id, s.session_id)
                ),
                linear_attribution AS (
                    SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
                           CAST(COUNT(DISTINCT sb.session_id) AS BIGINT) AS sessions,
                           CAST(ROUND(CAST(COALESCE(SUM(ut.total_conversions), 0) AS DECIMAL(18,8)) / NULLIF(MAX(sc.session_count), 0), 0) AS BIGINT) AS conversions,
                           CAST(ROUND(CAST(COALESCE(SUM(ur.total_revenue), 0) AS DECIMAL(18,8)) / NULLIF(MAX(sc.session_count), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue
                    FROM sessions_base sb
                    JOIN session_counts sc ON sb.visitor_id = sc.visitor_id
                    LEFT JOIN user_totals ut ON sb.visitor_id = ut.visitor_id
                    LEFT JOIN user_revenue ur ON sb.visitor_id = ur.visitor_id
                    GROUP BY 1,2,3,4,5
                )
                SELECT attribution_date, channel, medium, campaign, channel_group, sessions, conversions, attributed_revenue,
                       CAST(CASE WHEN sessions > 0 THEN ROUND(CAST(conversions AS DECIMAL(18,8)) / CAST(sessions AS DECIMAL(18,8)), 4) ELSE 0.0 END AS DECIMAL(10,4)) AS conversion_rate
                FROM linear_attribution
            """)
            actual = execute_query(conn, db_type, f"""
                SELECT attribution_date, channel, medium, campaign, channel_group,
                       CAST(sessions AS BIGINT), CAST(conversions AS BIGINT),
                       CAST(attributed_revenue AS DECIMAL(12,2)), CAST(conversion_rate AS DECIMAL(10,4))
                FROM {report_table} WHERE attribution_model = 'linear'
            """)
            exp_set = set(expected)
            act_set = set(actual)
            require(not (exp_set - act_set), f"linear: missing expected rows (sample: {list(exp_set - act_set)[:3]})")
            require(not (act_set - exp_set), f"linear: extra rows (sample: {list(act_set - exp_set)[:3]})")
        return 1.0
    finally:
        conn.close()


def component_9_assist_sessions_reconciliation():
    """Reconcile assist_sessions: sessions in a converting path that are not the last touch."""
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        date_btwn = _date_between(db_type)

        if db_type == 'snowflake':
            is_conv = "UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')"
            is_conv_c = "UPPER(CAST(c.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')"
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT s.session_id, COALESCE(s.visitor_id, s.session_id) AS visitor_id, s.session_start,
                           CASE WHEN {is_conv} THEN TRUE ELSE FALSE END AS is_converted,
                           CAST(s.session_start AS DATE) AS attribution_date,
                           COALESCE(s.utm_source, 'direct') AS channel, COALESCE(s.utm_medium, 'none') AS medium, COALESCE(s.utm_campaign, 'none') AS campaign
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                )
                SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, COUNT(DISTINCT sb.session_id) AS assist_sessions
                FROM sessions_base sb
                WHERE EXISTS (SELECT 1 FROM sessions_base c WHERE c.visitor_id = sb.visitor_id AND c.is_converted = true AND c.session_start > sb.session_start)
                GROUP BY 1, 2, 3, 4
            """)
        else:
            expected = execute_query(conn, db_type, f"""
                WITH sessions_base AS (
                    SELECT s.session_id, COALESCE(s.visitor_id, s.session_id) AS visitor_id, s.session_start, s.is_converted,
                           CAST(s.session_start AS DATE) AS attribution_date,
                           COALESCE(s.utm_source, 'direct') AS channel, COALESCE(s.utm_medium, 'none') AS medium, COALESCE(s.utm_campaign, 'none') AS campaign
                    FROM main.stg_ga__sessions s
                    WHERE s.session_id IS NOT NULL AND s.session_start IS NOT NULL
                      AND CAST(s.session_start AS DATE) {date_btwn}
                )
                SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, COUNT(DISTINCT sb.session_id) AS assist_sessions
                FROM sessions_base sb
                WHERE EXISTS (SELECT 1 FROM sessions_base c WHERE c.visitor_id = sb.visitor_id AND c.is_converted = true AND c.session_start > sb.session_start)
                GROUP BY 1, 2, 3, 4
            """)

        exp_map = {(str(r[0]), r[1], r[2], r[3]): int(r[4]) for r in expected}

        actual = execute_query(conn, db_type,
            f"SELECT attribution_date, channel, medium, campaign, assist_sessions FROM {report_table} WHERE attribution_model = 'last_touch'")
        for r in actual:
            key = (str(r[0]), r[1], r[2], r[3])
            exp_val = exp_map.get(key, 0)
            require(int(r[4]) == exp_val, f"assist_sessions mismatch for {key}: expected {exp_val}, got {int(r[4])}")
        return 1.0
    finally:
        conn.close()


def component_10_cross_model_consistency():
    """Total sessions, conversions, and revenue must match across all attribution models."""
    conn, db_type = get_db_connection()
    try:
        report_table = _get_report_table(db_type)
        totals = execute_query(conn, db_type, f"""
            SELECT attribution_model, SUM(sessions) AS s, SUM(conversions) AS c, SUM(attributed_revenue) AS r
            FROM {report_table}
            GROUP BY attribution_model ORDER BY attribution_model
        """)
        if not totals:
            return 1.0
        d = {r[0]: (int(r[1]), int(r[2]), float(r[3]) if r[3] is not None else 0.0) for r in totals}
        sessions = [v[0] for v in d.values()]
        conversions = [v[1] for v in d.values()]
        revenues = [v[2] for v in d.values()]
        require(len(set(sessions)) == 1, f"Total sessions differ across models: {d}")
        require(len(set(conversions)) == 1, f"Total conversions differ across models: {d}")
        require(len(set(revenues)) == 1 or all(abs(x - revenues[0]) < 0.02 for x in revenues), f"Total revenue differs across models: {d}")
        return 1.0
    finally:
        conn.close()


WEIGHTS = {f"component_{i}_{n}": 1.0 for i, n in enumerate([
    "structure", "dbt_pipeline", "schema", "data_quality",
    "model_presence", "last_touch_reconciliation", "first_touch_reconciliation",
    "linear_reconciliation", "assist_sessions_reconciliation", "cross_model_consistency"
], 1)}


def test_solution():
    """Run all multi-touch attribution verification components and assert all pass."""
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
