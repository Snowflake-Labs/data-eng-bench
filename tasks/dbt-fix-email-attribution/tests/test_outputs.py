"""
Comprehensive test suite for Email Attribution Report Fix task.
Validates data integrity, business logic, edge cases, and performance characteristics.
"""
import subprocess
import os
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
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')




def run_cmd(cmd, cwd="/app/dbt_project"):
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


def run_dbt_pipeline():
    deps_result = run_cmd(f"cd {get_dbt_project_dir()} && dbt deps", cwd="/app")
    if deps_result.returncode != 0:
        print(f"⚠ dbt deps had issues: {deps_result.stderr[:200]}")

    result = run_cmd(
        f"cd {get_dbt_project_dir()} && dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined",
        cwd="/app",
    )
    if result.returncode != 0:
        print(f"⚠ Reference models had issues: {result.stderr[:500]}")

    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type != 'snowflake':
        try:
            import duckdb
            conn = duckdb.connect("/app/database/retail.duckdb")
            for name in ["analytics.rpt_email_attribution_fixed", "ANALYTICS.rpt_email_attribution_fixed"]:
                try:
                    conn.execute(f"DROP TABLE IF EXISTS {name}")
                except Exception:
                    pass
            conn.close()
            print("✓ Cleaned up existing tables")
        except Exception as e:
            print(f"⚠ Cleanup warning: {e}")

    result = run_cmd("dbt run --select rpt_email_attribution_fixed --full-refresh", cwd="/app/dbt_project")
    if result.returncode != 0:
        error_msg = result.stderr if result.stderr else result.stdout
        require(False, f"dbt run failed: {error_msg[:1000]}")


@pytest.fixture(scope="module")
def setup_and_connection():
    print("\n" + "=" * 60)
    print("Email Attribution Report - Comprehensive Test Suite")
    print("=" * 60)

    require(os.path.exists("/app/dbt_project"), "dbt_project directory missing")
    require(
        os.path.exists("/app/dbt_project/models/marts/marketing/rpt_email_attribution_fixed.sql"),
        "Model file rpt_email_attribution_fixed.sql missing"
    )

    print("✓ Project structure validated")
    run_dbt_pipeline()
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_model_exists_and_compiles(setup_and_connection):
    """Test 1: Verify model file exists and dbt compilation succeeds"""
    model_path = "/app/dbt_project/models/marts/marketing/rpt_email_attribution_fixed.sql"
    require(os.path.exists(model_path), f"Model file not found at {model_path}")

    conn, db_type = setup_and_connection
    table_exists = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE LOWER(table_schema) = 'analytics'
          AND LOWER(table_name) = 'rpt_email_attribution_fixed'
        """
    )

    if table_exists == 0:
        if db_type == 'duckdb':
            try:
                cols = execute_query(conn, db_type, "SELECT * FROM pragma_table_info('analytics.rpt_email_attribution_fixed')")
                require(len(cols) > 0, "Table exists but has no columns")
            except Exception:
                require(False, "Table analytics.rpt_email_attribution_fixed does not exist")
        else:
            require(False, "Table analytics.rpt_email_attribution_fixed does not exist")

    print("✓ Test 1: Model exists and compiles successfully")


def test_required_columns_present(setup_and_connection):
    """Test 2: Verify all required columns exist with correct data types"""
    conn, db_type = setup_and_connection

    if db_type == 'duckdb':
        cols = execute_query(conn, db_type,
            """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_email_attribution_fixed')
            ORDER BY cid
            """
        )
    else:
        cols = execute_query(conn, db_type,
            """
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE LOWER(table_schema) = 'analytics'
              AND LOWER(table_name) = 'rpt_email_attribution_fixed'
            ORDER BY ordinal_position
            """
        )

    col_dict = {c[0].lower(): c[1].lower() for c in cols}
    required = {
        "attribution_date", "channel", "medium", "campaign",
        "sessions", "conversions", "attributed_revenue", "conversion_rate"
    }

    missing = required - set(col_dict.keys())
    require(not missing, f"Missing required columns: {missing}")

    require("date" in col_dict.get("attribution_date", ""), "attribution_date must be DATE type")
    require("int" in col_dict.get("sessions", "") or "bigint" in col_dict.get("sessions", "") or "number" in col_dict.get("sessions", ""),
            "sessions must be INTEGER/BIGINT")
    require("int" in col_dict.get("conversions", "") or "bigint" in col_dict.get("conversions", "") or "number" in col_dict.get("conversions", ""),
            "conversions must be INTEGER/BIGINT")
    require("decimal" in col_dict.get("attributed_revenue", "") or "double" in col_dict.get("attributed_revenue", "") or "number" in col_dict.get("attributed_revenue", ""),
            "attributed_revenue must be NUMERIC")
    require("decimal" in col_dict.get("conversion_rate", "") or "double" in col_dict.get("conversion_rate", "") or "number" in col_dict.get("conversion_rate", ""),
            "conversion_rate must be NUMERIC")

    print("✓ Test 2: All required columns present with correct types")


def test_date_range_constraint(setup_and_connection):
    """Test 3: Verify data is limited to last 90 days"""
    conn, db_type = setup_and_connection

    date_stats = execute_query(conn, db_type,
        """
        SELECT
            MIN(attribution_date) as min_date,
            MAX(attribution_date) as max_date,
            COUNT(DISTINCT attribution_date) as date_count,
            SUM(CASE WHEN attribution_date < DATE '2025-10-04' THEN 1 ELSE 0 END) as too_old,
            SUM(CASE WHEN attribution_date > CURRENT_DATE THEN 1 ELSE 0 END) as future
        FROM analytics.rpt_email_attribution_fixed
        """
    )[0]

    min_date, max_date, date_count, too_old, future = date_stats

    require(date_count > 0, "No dates found in table")
    require(too_old == 0, f"Found {too_old} rows with dates before cutoff 2025-10-04")
    require(future == 0, f"Found {future} rows with future dates")

    if min_date:
        require(str(min_date) >= '2025-10-04', f"Oldest date is before cutoff 2025-10-04: {min_date}")

    print(f"✓ Test 3: Date range constraint validated ({date_count} distinct dates)")


def test_utm_parameter_handling(setup_and_connection):
    """Test 4: Verify UTM parameter normalization and default values"""
    conn, db_type = setup_and_connection

    null_check = execute_query(conn, db_type,
        """
        SELECT
            SUM(CASE WHEN channel IS NULL OR channel = '' THEN 1 ELSE 0 END) as null_channel,
            SUM(CASE WHEN medium IS NULL OR medium = '' THEN 1 ELSE 0 END) as null_medium,
            SUM(CASE WHEN campaign IS NULL OR campaign = '' THEN 1 ELSE 0 END) as null_campaign
        FROM analytics.rpt_email_attribution_fixed
        """
    )[0]

    null_channel, null_medium, null_campaign = null_check
    require(null_channel == 0, f"Found {null_channel} NULL/empty channel values")
    require(null_medium == 0, f"Found {null_medium} NULL/empty medium values")
    require(null_campaign == 0, f"Found {null_campaign} NULL/empty campaign values")

    direct_rows = execute_scalar(conn, db_type,
        "SELECT COUNT(*) FROM analytics.rpt_email_attribution_fixed WHERE channel = 'direct'"
    )

    none_medium_rows = execute_scalar(conn, db_type,
        "SELECT COUNT(*) FROM analytics.rpt_email_attribution_fixed WHERE medium = 'none'"
    )

    print(f"✓ Test 4: UTM parameter handling validated (direct: {direct_rows}, none medium: {none_medium_rows})")


def test_conversion_rate_calculation(setup_and_connection):
    """Test 5: Verify conversion rate is calculated correctly"""
    conn, db_type = setup_and_connection

    invalid_rates = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE conversion_rate < 0.0 OR conversion_rate > 1.0
        """
    )
    require(invalid_rates == 0, f"Found {invalid_rates} rows with conversion_rate outside [0, 1]")

    precision_issues = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE conversion_rate != ROUND(conversion_rate, 4)
        """
    )
    require(precision_issues == 0, f"Found {precision_issues} rows with incorrect precision")

    calc_errors = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE sessions > 0
          AND ABS(conversion_rate - ROUND(CAST(conversions AS DOUBLE) / CAST(sessions AS DOUBLE), 4)) > 0.0001
        """
    )
    require(calc_errors == 0, f"Found {calc_errors} rows with incorrect conversion_rate calculation")

    zero_issue = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE sessions = 0 AND conversion_rate != 0.0
        """
    )
    require(zero_issue == 0, f"Found {zero_issue} rows with 0 sessions but non-zero rate")

    print("✓ Test 5: Conversion rate calculation validated")


def test_revenue_handling(setup_and_connection):
    """Test 6: Verify revenue attribution and precision"""
    conn, db_type = setup_and_connection

    precision_issues = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE attributed_revenue != ROUND(attributed_revenue, 2)
        """
    )
    require(precision_issues == 0, f"Found {precision_issues} rows with revenue not rounded to 2 decimals")

    negative_revenue = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE attributed_revenue < 0
        """
    )
    require(negative_revenue == 0, f"Found {negative_revenue} rows with negative revenue")

    invalid_conv = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE conversions > sessions
        """
    )
    require(invalid_conv == 0, f"Found {invalid_conv} rows where conversions > sessions")

    print("✓ Test 6: Revenue handling validated")


def test_session_aggregation(setup_and_connection):
    """Test 7: Verify session counting and aggregation logic"""
    conn, db_type = setup_and_connection

    duplicates = execute_query(conn, db_type,
        """
        SELECT attribution_date, channel, medium, campaign, COUNT(*) as cnt
        FROM analytics.rpt_email_attribution_fixed
        GROUP BY attribution_date, channel, medium, campaign
        HAVING COUNT(*) > 1
        """
    )
    require(len(duplicates) == 0, f"Found {len(duplicates)} duplicate dimension combinations")

    report_total = execute_scalar(conn, db_type,
        "SELECT SUM(sessions) FROM analytics.rpt_email_attribution_fixed"
    ) or 0

    source_total = execute_scalar(conn, db_type,
        """
        SELECT COUNT(DISTINCT TRIM(CAST(session_id AS VARCHAR)))
        FROM main.stg_ga__sessions
        WHERE session_id IS NOT NULL
          AND TRIM(CAST(session_id AS VARCHAR)) != ''
          AND session_start IS NOT NULL
              AND CAST(session_start AS DATE) >= DATE '2025-10-04'
              AND CAST(session_start AS DATE) <= DATE '2026-01-02'
        """
    ) or 0

    if source_total > 0:
        variance = abs(report_total - source_total) / source_total
        require(variance < 0.05,
                f"Session count mismatch: report={report_total}, source={source_total}, variance={variance:.2%}")

    print(f"✓ Test 7: Session aggregation validated (report: {report_total}, source: {source_total})")


def test_data_quality_integrity(setup_and_connection):
    """Test 8: Comprehensive data quality and integrity checks"""
    conn, db_type = setup_and_connection

    quality = execute_query(conn, db_type,
        """
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN attribution_date IS NULL THEN 1 ELSE 0 END) as null_dates,
            SUM(CASE WHEN sessions IS NULL THEN 1 ELSE 0 END) as null_sessions,
            SUM(CASE WHEN conversions IS NULL THEN 1 ELSE 0 END) as null_conversions,
            SUM(CASE WHEN attributed_revenue IS NULL THEN 1 ELSE 0 END) as null_revenue,
            SUM(CASE WHEN conversion_rate IS NULL THEN 1 ELSE 0 END) as null_rate,
            SUM(CASE WHEN sessions < 0 THEN 1 ELSE 0 END) as neg_sessions,
            SUM(CASE WHEN conversions < 0 THEN 1 ELSE 0 END) as neg_conversions
        FROM analytics.rpt_email_attribution_fixed
        """
    )[0]

    total, null_dates, null_sessions, null_conversions, null_revenue, null_rate, neg_sessions, neg_conversions = quality

    require(total > 0, "Table is empty")
    require(null_dates == 0, f"Found {null_dates} NULL dates")
    require(null_sessions == 0, f"Found {null_sessions} NULL sessions")
    require(null_conversions == 0, f"Found {null_conversions} NULL conversions")
    require(null_revenue == 0, f"Found {null_revenue} NULL revenue")
    require(null_rate == 0, f"Found {null_rate} NULL conversion_rate")
    require(neg_sessions == 0, f"Found {neg_sessions} negative sessions")
    require(neg_conversions == 0, f"Found {neg_conversions} negative conversions")

    print(f"✓ Test 8: Data quality integrity validated ({total} rows)")


def test_email_channel_presence(setup_and_connection):
    """Test 9: Verify email channels are present in the data"""
    conn, db_type = setup_and_connection

    email_rows = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE LOWER(channel) LIKE '%email%'
           OR LOWER(medium) IN ('email', 'em', 'email marketing', 'e-mail')
        """
    )

    require(email_rows > 0, "Expected email-related rows but found none")

    invalid_email = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE (LOWER(channel) LIKE '%email%' OR LOWER(medium) IN ('email', 'em'))
          AND (sessions IS NULL OR sessions < 0)
        """
    )
    require(invalid_email == 0, f"Found {invalid_email} email rows with invalid data")

    print(f"✓ Test 9: Email channel presence validated ({email_rows} email-related rows)")


def test_conversion_count_accuracy(setup_and_connection):
    """Test 10: Verify conversion counts match source data"""
    conn, db_type = setup_and_connection

    report_conversions = execute_scalar(conn, db_type,
        "SELECT SUM(conversions) FROM analytics.rpt_email_attribution_fixed"
    ) or 0

    # In Snowflake, is_converted is a NUMBER column. Using 'is_converted = true'
    # coerces TRUE to 1 and only matches exact value 1, missing other truthy
    # numeric values. Use CAST(... AS BOOLEAN) for correct boolean interpretation
    # across both DuckDB (where it may be BOOLEAN) and Snowflake (where it is NUMBER).
    if db_type == 'snowflake':
        source_conversions = execute_scalar(conn, db_type,
            """
            SELECT COUNT(DISTINCT TRIM(CAST(session_id AS VARCHAR)))
            FROM main.stg_ga__sessions
            WHERE session_id IS NOT NULL
              AND TRIM(CAST(session_id AS VARCHAR)) != ''
              AND session_start IS NOT NULL
              AND CAST(session_start AS DATE) >= '2025-10-04'
              AND CAST(session_start AS DATE) <= '2026-01-02'
              AND UPPER(CAST(is_converted AS VARCHAR)) IN ('TRUE', 'T', 'YES', 'Y', '1')
            """
        ) or 0
    else:
        source_conversions = execute_scalar(conn, db_type,
            """
            SELECT COUNT(DISTINCT TRIM(CAST(session_id AS VARCHAR)))
            FROM main.stg_ga__sessions
            WHERE session_id IS NOT NULL
              AND TRIM(CAST(session_id AS VARCHAR)) != ''
              AND session_start IS NOT NULL
              AND CAST(session_start AS DATE) >= DATE '2025-10-04'
              AND CAST(session_start AS DATE) <= DATE '2026-01-02'
              AND is_converted = true
            """
        ) or 0

    if source_conversions > 0:
        variance = abs(report_conversions - source_conversions) / source_conversions
        require(variance < 0.05,
                f"Conversion count mismatch: report={report_conversions}, source={source_conversions}, variance={variance:.2%}")

    non_integer = execute_scalar(conn, db_type,
        """
        SELECT COUNT(*)
        FROM analytics.rpt_email_attribution_fixed
        WHERE conversions != FLOOR(conversions)
        """
    )
    require(non_integer == 0, f"Found {non_integer} rows with non-integer conversions")

    print(f"✓ Test 10: Conversion count accuracy validated (report: {report_conversions}, source: {source_conversions})")
