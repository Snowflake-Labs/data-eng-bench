"""
Test verifier for Paid Search Attribution Fix task.
Validates schema, data quality, and reconciliation against source data.
Supports both DuckDB and Snowflake backends.
"""
import subprocess
import pytest
import os


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
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE') or '/app/dbt_models_snowflake'
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB') or '/app/dbt_models_duckdb'


def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:500]}")
    return result


def require(condition, msg):
    if not condition:
        raise AssertionError(msg)


def run_dbt_pipeline(db_type):
    """Run dbt pipeline - build reference models then agent's model."""
    project_dir = get_dbt_project_dir()

    if db_type == 'duckdb':
        # Clean up existing table for DuckDB before running dbt
        try:
            import duckdb
            drop_conn = duckdb.connect("/app/database/retail.duckdb")
            for name in [
                "analytics.rpt_paid_search_attribution_fixed",
                "ANALYTICS.rpt_paid_search_attribution_fixed",
                "rpt_paid_search_attribution_fixed",
            ]:
                try:
                    drop_conn.execute(f"DROP TABLE IF EXISTS {name}")
                except Exception:
                    pass
            drop_conn.close()
            print("Cleaned up any existing rpt_paid_search_attribution_fixed table")
        except Exception as e:
            print(f"Warning: Could not clean up existing table (may not exist): {e}")

    # Build reference models and agent model from the same project
    deps_result = run_cmd(f"DBT_PROFILES_DIR={project_dir} dbt deps", cwd=project_dir)
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps had issues: {deps_result.stderr[:200]}")

    ref_result = run_cmd(
        f"DBT_PROFILES_DIR={project_dir} dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined",
        cwd=project_dir,
    )
    if ref_result.returncode != 0:
        print(f"Warning: Reference model run had issues (may already exist): {ref_result.stderr[:500]}")

    result = run_cmd(
        f"DBT_PROFILES_DIR={project_dir} dbt run --select rpt_paid_search_attribution_fixed --full-refresh",
        cwd=project_dir
    )
    if result.returncode != 0:
        error_msg = result.stderr if result.stderr else result.stdout
        require(False, f"dbt run failed: {error_msg[:1000]}")


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def setup_and_connection():
    """Setup test environment and provide database connection."""
    print("\n" + "=" * 50)
    print("Testing Paid Search Attribution Report Fix")
    print("=" * 50)

    dbt_dir = get_dbt_project_dir()
    if not os.path.exists(dbt_dir):
        raise AssertionError(f"dbt_project directory missing - agent must create {dbt_dir} first")
    if not os.path.exists(os.path.join(dbt_dir, "models/marts/marketing/rpt_paid_search_attribution_fixed.sql")):
        raise AssertionError("rpt_paid_search_attribution_fixed.sql model missing - agent must create this model")

    print("Project structure validated")

    # Run dbt pipeline BEFORE opening the test connection to avoid DuckDB
    # concurrent connection config mismatch (read-only vs read-write)
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    run_dbt_pipeline(db_type)
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ============ TESTS ============


def test_structure():
    """Verify the rpt_paid_search_attribution_fixed.sql model file exists in the project."""
    dbt_dir = get_dbt_project_dir()
    if not os.path.exists(os.path.join(dbt_dir, "models/marts/marketing/rpt_paid_search_attribution_fixed.sql")):
        raise AssertionError("rpt_paid_search_attribution_fixed.sql model missing - agent must create this model")
    print("Project structure validated")


def test_schema(setup_and_connection):
    """Validate required columns exist with correct data types in the attribution report."""
    conn, db_type = setup_and_connection

    if db_type == 'snowflake':
        cols = execute_query(conn, db_type, """
            SELECT lower(column_name) AS column_name, lower(data_type) AS data_type
            FROM information_schema.columns
            WHERE lower(table_schema) = 'analytics'
              AND lower(table_name) = 'rpt_paid_search_attribution_fixed'
            ORDER BY ordinal_position
        """)
    else:
        cols = execute_query(conn, db_type, """
            SELECT
                name AS column_name,
                type AS data_type
            FROM pragma_table_info('analytics.rpt_paid_search_attribution_fixed')
            ORDER BY cid
        """)

    col_names = {c[0].lower() for c in cols}
    required = {
        "attribution_date",
        "channel",
        "medium",
        "campaign",
        "sessions",
        "conversions",
        "attributed_revenue",
        "conversion_rate",
    }
    missing = required - col_names
    require(not missing, f"Missing required columns: {missing}")

    col_dict = {c[0].lower(): c[1].lower() for c in cols}

    if db_type == 'snowflake':
        require(
            "date" in col_dict.get("attribution_date", ""),
            "attribution_date must be DATE type"
        )
        require(
            "number" in col_dict.get("sessions", "") or "int" in col_dict.get("sessions", ""),
            "sessions must be numeric type"
        )
        require(
            "number" in col_dict.get("conversions", "") or "int" in col_dict.get("conversions", ""),
            "conversions must be numeric type"
        )
    else:
        require("date" in col_dict.get("attribution_date", ""), "attribution_date must be DATE type")
        require(
            "integer" in col_dict.get("sessions", "") or "bigint" in col_dict.get("sessions", ""),
            "sessions must be INTEGER type",
        )
        require(
            "integer" in col_dict.get("conversions", "") or "bigint" in col_dict.get("conversions", ""),
            "conversions must be INTEGER type",
        )

    print("Schema validated")


def test_data_quality(setup_and_connection):
    """Check for no NULL key columns and valid conversion rates not exceeding session counts."""
    conn, db_type = setup_and_connection
    null_check = execute_query(conn, db_type, """
        SELECT
            COUNT(*) as total_rows,
            SUM(CASE WHEN attribution_date IS NULL THEN 1 ELSE 0 END) as null_dates,
            SUM(CASE WHEN channel IS NULL THEN 1 ELSE 0 END) as null_channels,
            SUM(CASE WHEN medium IS NULL THEN 1 ELSE 0 END) as null_mediums,
            SUM(CASE WHEN campaign IS NULL THEN 1 ELSE 0 END) as null_campaigns,
            SUM(CASE WHEN sessions IS NULL THEN 1 ELSE 0 END) as null_sessions,
            SUM(CASE WHEN conversions IS NULL THEN 1 ELSE 0 END) as null_conversions
        FROM analytics.rpt_paid_search_attribution_fixed
    """)

    (
        total,
        null_dates,
        null_channels,
        null_mediums,
        null_campaigns,
        null_sessions,
        null_conversions,
    ) = null_check[0]

    require(int(null_dates) == 0, f"Found {null_dates} NULL attribution_date values")
    require(int(null_channels) == 0, f"Found {null_channels} NULL channel values")
    require(int(null_mediums) == 0, f"Found {null_mediums} NULL medium values")
    require(int(null_campaigns) == 0, f"Found {null_campaigns} NULL campaign values")
    require(int(null_sessions) == 0, f"Found {null_sessions} NULL sessions values")
    require(int(null_conversions) == 0, f"Found {null_conversions} NULL conversions values")

    invalid_rates = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_paid_search_attribution_fixed
        WHERE conversion_rate < 0.0 OR conversion_rate > 1.0
    """)

    require(int(invalid_rates) == 0, f"Found {invalid_rates} rows with invalid conversion_rate (not between 0.0 and 1.0)")

    invalid_counts = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_paid_search_attribution_fixed
        WHERE conversions > sessions
    """)

    require(int(invalid_counts) == 0, f"Found {invalid_counts} rows where conversions > sessions")

    print(f"Data quality validated ({int(total)} rows)")


def test_paid_search_focus(setup_and_connection):
    """Ensure paid search traffic is present (google/cpc-style)."""
    conn, db_type = setup_and_connection
    paid_rows = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM analytics.rpt_paid_search_attribution_fixed
        WHERE lower(channel) LIKE '%google%' OR lower(medium) IN ('cpc','paid','ppc')
    """)
    require(int(paid_rows) > 0, "Expected at least some paid search rows (google/cpc/paid/ppc)")
    print("Paid search rows present")


def test_aggregation(setup_and_connection):
    """Verify report session counts are within 5% of source session counts from the last 90 days."""
    conn, db_type = setup_and_connection

    if db_type == 'snowflake':
        source_sessions = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT session_id)
            FROM main.stg_ga__sessions
            WHERE CAST(session_start AS DATE) >= DATEADD(day, -90, (SELECT MAX(CAST(session_start AS DATE)) FROM main.stg_ga__sessions))
              AND session_id IS NOT NULL
        """)
    else:
        source_sessions = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT session_id)
            FROM main.stg_ga__sessions
            WHERE CAST(session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM main.stg_ga__sessions) - INTERVAL '90 days'
              AND session_id IS NOT NULL
        """)

    result_sessions = execute_scalar(conn, db_type, """
        SELECT SUM(sessions)
        FROM analytics.rpt_paid_search_attribution_fixed
    """)

    source_sessions = int(source_sessions)
    result_sessions = int(result_sessions)

    variance = abs(source_sessions - result_sessions) / max(source_sessions, 1)
    require(variance < 0.05, f"Session count mismatch: source={source_sessions}, result={result_sessions}, variance={variance:.2%}")
    print(f"Aggregation validated (source: {source_sessions}, result: {result_sessions})")


def _revenue_uses_joined(conn, db_type):
    """Return True if main.int_sessions_events_joined exists and has t2_event_value (prefer joined per instruction)."""
    try:
        if db_type == 'snowflake':
            cols = execute_query(conn, db_type, """
                SELECT LOWER(column_name) AS column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = 'main'
                  AND LOWER(table_name) = 'int_sessions_events_joined'
            """)
        else:
            cols = execute_query(conn, db_type, """
                SELECT LOWER(column_name) AS column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = 'main'
                  AND LOWER(table_name) = 'int_sessions_events_joined'
            """)
        names = {c[0] for c in cols}
        return "t2_event_value" in names and "t2_event_name" in names
    except Exception:
        return False


def test_prefers_joined_for_attributed_revenue(setup_and_connection):
    """When int_sessions_events_joined is available, attributed_revenue must match joined-based revenue (instruction)."""
    conn, db_type = setup_and_connection
    if not _revenue_uses_joined(conn, db_type):
        pytest.skip("int_sessions_events_joined not available; prefer-joined requirement N/A")

    if db_type == 'snowflake':
        joined_total = execute_scalar(conn, db_type, """
            SELECT CAST(ROUND(COALESCE(SUM(rev.conversion_value), 0), 2) AS DECIMAL(12,2))
            FROM (
                SELECT
                    j.session_id,
                    ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
                FROM main.int_sessions_events_joined j
                JOIN main.stg_ga__sessions s ON j.session_id = s.session_id
                WHERE s.is_converted = true
                  AND CAST(s.session_start AS DATE) >= DATEADD(day, -90, (SELECT MAX(CAST(session_start AS DATE)) FROM main.stg_ga__sessions))
                  AND j.t2_event_name = 'purchase'
                GROUP BY j.session_id
            ) rev
        """)
    else:
        joined_total = execute_scalar(conn, db_type, """
            SELECT CAST(ROUND(COALESCE(SUM(rev.conversion_value), 0), 2) AS DECIMAL(12,2))
            FROM (
                SELECT
                    j.session_id,
                    ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
                FROM main.int_sessions_events_joined j
                JOIN main.stg_ga__sessions s ON j.session_id = s.session_id
                WHERE s.is_converted = true
                  AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM main.stg_ga__sessions) - INTERVAL '90 days'
                  AND j.t2_event_name = 'purchase'
                GROUP BY j.session_id
            ) rev
        """)

    actual_total = execute_scalar(conn, db_type, """
        SELECT SUM(CAST(attributed_revenue AS DECIMAL(12,2))) FROM analytics.rpt_paid_search_attribution_fixed
    """)

    joined_total = float(joined_total) if joined_total is not None else 0.0
    actual_total = float(actual_total) if actual_total is not None else 0.0
    require(
        actual_total == joined_total,
        f"attributed_revenue must prefer int_sessions_events_joined: expected total {joined_total}, got {actual_total}",
    )
    print("Prefer int_sessions_events_joined for attributed_revenue validated")


def test_reconciliation(setup_and_connection):
    """Reconcile output to source: prefer int_sessions_events_joined for revenue when available, else stg_ga__events."""
    conn, db_type = setup_and_connection
    use_joined = _revenue_uses_joined(conn, db_type)

    if db_type == 'snowflake':
        interval_clause = "DATEADD(day, -90, (SELECT MAX(CAST(session_start AS DATE)) FROM main.stg_ga__sessions))"
    else:
        interval_clause = "(SELECT MAX(CAST(session_start AS DATE)) FROM main.stg_ga__sessions) - INTERVAL '90 days'"

    if use_joined:
        conversion_revenue_sql = f"""
        conversion_revenue AS (
            SELECT
                j.session_id,
                ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM main.int_sessions_events_joined j
            JOIN main.stg_ga__sessions s ON j.session_id = s.session_id
            WHERE s.is_converted = true
              AND CAST(s.session_start AS DATE) >= {interval_clause}
              AND j.t2_event_name = 'purchase'
            GROUP BY j.session_id
        )
        """
    else:
        conversion_revenue_sql = f"""
        conversion_revenue AS (
            SELECT
                e.session_id,
                ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM main.stg_ga__events e
            JOIN main.stg_ga__sessions s ON e.session_id = s.session_id
            WHERE s.is_converted = true
              AND CAST(s.session_start AS DATE) >= {interval_clause}
              AND e.event_name = 'purchase'
              AND e.event_value IS NOT NULL
            GROUP BY e.session_id
        )
        """

    expected = execute_query(conn, db_type, f"""
        WITH sessions_base AS (
            SELECT DISTINCT
                s.session_id,
                CAST(s.session_start AS DATE) AS attribution_date,
                COALESCE(s.utm_source, 'direct') AS channel,
                COALESCE(s.utm_medium, 'none') AS medium,
                COALESCE(s.utm_campaign, 'none') AS campaign,
                s.is_converted AS is_converted,
                s.session_start
            FROM main.stg_ga__sessions s
            WHERE s.session_id IS NOT NULL
              AND s.session_start IS NOT NULL
              AND CAST(s.session_start AS DATE) >= {interval_clause}
        ),
        {conversion_revenue_sql}
        SELECT
            sb.attribution_date,
            sb.channel,
            sb.medium,
            sb.campaign,
            CAST(COUNT(DISTINCT sb.session_id) AS BIGINT) AS sessions,
            CAST(SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS BIGINT) AS conversions,
            CAST(ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
            CAST(
                CASE
                    WHEN COUNT(DISTINCT sb.session_id) > 0 THEN
                        ROUND(
                            CAST(SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS DECIMAL(18,8)) /
                            CAST(COUNT(DISTINCT sb.session_id) AS DECIMAL(18,8)),
                            4
                        )
                    ELSE 0.0
                END
                AS DECIMAL(10,4)
            ) AS conversion_rate
        FROM sessions_base sb
        LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
        GROUP BY 1,2,3,4
    """)

    actual = execute_query(conn, db_type, """
        SELECT
            attribution_date,
            channel,
            medium,
            campaign,
            CAST(sessions AS BIGINT) AS sessions,
            CAST(conversions AS BIGINT) AS conversions,
            CAST(attributed_revenue AS DECIMAL(12,2)) AS attributed_revenue,
            CAST(conversion_rate AS DECIMAL(10,4)) AS conversion_rate
        FROM analytics.rpt_paid_search_attribution_fixed
    """)

    # Normalize tuples for comparison - Snowflake may return Decimal types
    def normalize_row(row):
        result = []
        for val in row:
            if hasattr(val, 'date'):
                result.append(val.date())
            elif isinstance(val, str):
                result.append(val)
            else:
                try:
                    # Try float conversion for numeric types (handles Decimal)
                    result.append(float(val))
                except (TypeError, ValueError):
                    result.append(val)
        return tuple(result)

    exp_set = set(normalize_row(r) for r in expected)
    act_set = set(normalize_row(r) for r in actual)
    missing = list(exp_set - act_set)
    extra = list(act_set - exp_set)
    require(len(missing) == 0, f"Output is missing {len(missing)} expected rows (sample: {missing[:3]})")
    require(len(extra) == 0, f"Output has {len(extra)} extra unexpected rows (sample: {extra[:3]})")
    print(f"Source reconciliation validated ({len(actual)} rows matched)")
