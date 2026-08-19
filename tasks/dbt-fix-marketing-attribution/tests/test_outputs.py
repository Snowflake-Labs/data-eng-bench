"""
Test verifier for Marketing Attribution Report Fix task.
Validates UTM parsing, conversion logic, and attribution metrics.
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
        private_key_pem, password=passphrase_bytes, backend=default_backend()
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


def _get_schema():
    """Get the schema for the output model based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'analytics'


SCHEMA = _get_schema()

SOURCE_SCHEMA = SCHEMA


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
    """Run dbt pipeline - first reference models, then agent's model."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        # For Snowflake, run reference models from the Snowflake project
        ref_dir = "/app/dbt_models_snowflake"
        deps_result = run_cmd(f"cd {ref_dir} && dbt deps", cwd=ref_dir)
        if deps_result.returncode != 0:
            print(f"dbt deps had issues: {deps_result.stderr[:200]}")

        result = run_cmd(
            f"cd {ref_dir} && dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined",
            cwd=ref_dir,
        )
        if result.returncode != 0:
            print(f"Reference models run had issues: {result.stderr[:500]}")

        # Run the agent's model
        result = run_cmd("dbt run --select rpt_attribution_fixed", cwd="/app/dbt_project")
        if result.returncode != 0:
            error_msg = result.stderr if result.stderr else result.stdout
            require(False, f"dbt run failed: {error_msg[:1000]}")
    else:
        # DuckDB path
        deps_result = run_cmd("cd /app/dbt_models_duckdb && dbt deps", cwd="/app")
        if deps_result.returncode != 0:
            print(f"dbt deps had issues: {deps_result.stderr[:200]}")

        result = run_cmd(
            "cd /app/dbt_models_duckdb && dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined",
            cwd="/app",
        )
        if result.returncode != 0:
            print(f"Reference models run had issues: {result.stderr[:500]}")

        # Drop existing table if it exists
        try:
            import duckdb
            conn = duckdb.connect("/app/database/retail.duckdb")
            try:
                conn.execute("DROP TABLE IF EXISTS analytics.rpt_attribution_fixed")
            except Exception:
                pass
            try:
                conn.execute("DROP TABLE IF EXISTS ANALYTICS.rpt_attribution_fixed")
            except Exception:
                pass
            try:
                conn.execute("DROP TABLE IF EXISTS rpt_attribution_fixed")
            except Exception:
                pass
            conn.close()
            print("Cleaned up any existing rpt_attribution_fixed table")
        except Exception as e:
            print(f"Could not clean up existing table: {e}")

        # Run agent's model
        result = run_cmd("dbt run --select rpt_attribution_fixed --full-refresh", cwd="/app/dbt_project")
        if result.returncode != 0:
            error_msg = result.stderr if result.stderr else result.stdout
            require(False, f"dbt run failed: {error_msg[:1000]}")


@pytest.fixture(scope="module")
def setup_and_connection():
    """Setup test environment and provide database connection."""
    print("\n" + "=" * 50)
    print("Testing Marketing Attribution Report Fix")
    print("=" * 50)

    # Check if project exists first
    if not os.path.exists("/app/dbt_project"):
        raise AssertionError("dbt_project directory missing - agent must create /app/dbt_project first")
    if not os.path.exists("/app/dbt_project/models/marts/marketing/rpt_attribution_fixed.sql"):
        raise AssertionError("rpt_attribution_fixed.sql model missing - agent must create this model")

    print("Project structure validated")

    # Run dbt pipeline
    run_dbt_pipeline()

    # Provide connection
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_structure():
    """Test 1: Validate project structure exists."""
    if not os.path.exists("/app/dbt_project"):
        raise AssertionError("dbt_project directory missing - agent must create this first")
    if not os.path.exists("/app/dbt_project/models"):
        raise AssertionError("dbt_project/models directory missing")
    if not os.path.exists("/app/dbt_project/models/marts/marketing/rpt_attribution_fixed.sql"):
        raise AssertionError("rpt_attribution_fixed.sql model missing - agent must create this model")
    print("Project structure validated")


def test_schema(setup_and_connection):
    """Test 2: Validate output schema matches requirements."""
    conn, db_type = setup_and_connection

    cols = execute_query(conn, db_type, f"""
        SELECT
            lower(column_name) AS column_name,
            lower(data_type) AS data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = lower('{SCHEMA}')
          AND lower(table_name) = 'rpt_attribution_fixed'
        ORDER BY ordinal_position
    """)

    col_names = {c[0] for c in cols}
    required = {
        'attribution_date', 'channel', 'medium', 'campaign',
        'sessions', 'conversions', 'attributed_revenue', 'conversion_rate'
    }
    missing = required - col_names
    require(not missing, f"Missing required columns: {missing}")

    # Check data types
    col_dict = {c[0]: c[1] for c in cols}
    require('date' in col_dict.get('attribution_date', ''),
            "attribution_date must be DATE type")

    # For sessions/conversions, allow integer/bigint/number
    sessions_type = col_dict.get('sessions', '')
    require('int' in sessions_type or 'bigint' in sessions_type or 'number' in sessions_type,
            f"sessions must be INTEGER type, got: {sessions_type}")

    conversions_type = col_dict.get('conversions', '')
    require('int' in conversions_type or 'bigint' in conversions_type or 'number' in conversions_type,
            f"conversions must be INTEGER type, got: {conversions_type}")

    print("Schema validated")


def test_data_quality(setup_and_connection):
    """Test 3: Validate data quality requirements."""
    conn, db_type = setup_and_connection

    null_check = execute_query(conn, db_type, f"""
        SELECT
            COUNT(*) as total_rows,
            SUM(CASE WHEN attribution_date IS NULL THEN 1 ELSE 0 END) as null_dates,
            SUM(CASE WHEN channel IS NULL THEN 1 ELSE 0 END) as null_channels,
            SUM(CASE WHEN medium IS NULL THEN 1 ELSE 0 END) as null_mediums,
            SUM(CASE WHEN campaign IS NULL THEN 1 ELSE 0 END) as null_campaigns,
            SUM(CASE WHEN sessions IS NULL THEN 1 ELSE 0 END) as null_sessions,
            SUM(CASE WHEN conversions IS NULL THEN 1 ELSE 0 END) as null_conversions
        FROM {SCHEMA}.rpt_attribution_fixed
    """)

    total = int(null_check[0][0])
    null_dates = int(null_check[0][1])
    null_channels = int(null_check[0][2])
    null_mediums = int(null_check[0][3])
    null_campaigns = int(null_check[0][4])
    null_sessions = int(null_check[0][5])
    null_conversions = int(null_check[0][6])

    require(null_dates == 0, f"Found {null_dates} NULL attribution_date values")
    require(null_channels == 0, f"Found {null_channels} NULL channel values")
    require(null_mediums == 0, f"Found {null_mediums} NULL medium values")
    require(null_campaigns == 0, f"Found {null_campaigns} NULL campaign values")
    require(null_sessions == 0, f"Found {null_sessions} NULL sessions values")
    require(null_conversions == 0, f"Found {null_conversions} NULL conversions values")

    # Check conversion_rate is valid (0.0 to 1.0)
    invalid_rates = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_attribution_fixed
        WHERE conversion_rate < 0.0 OR conversion_rate > 1.0
    """))

    require(invalid_rates == 0, f"Found {invalid_rates} rows with invalid conversion_rate (not between 0.0 and 1.0)")

    # Check sessions >= conversions
    invalid_counts = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_attribution_fixed
        WHERE conversions > sessions
    """))

    require(invalid_counts == 0, f"Found {invalid_counts} rows where conversions > sessions")

    print(f"Data quality validated ({total} rows)")


def test_utm_extraction(setup_and_connection):
    """Test 4: Validate UTM parameters are extracted correctly."""
    conn, db_type = setup_and_connection

    sample = execute_query(conn, db_type, f"""
        SELECT
            r.channel,
            r.medium,
            r.campaign,
            COUNT(*) as row_count
        FROM {SCHEMA}.rpt_attribution_fixed r
        GROUP BY r.channel, r.medium, r.campaign
        ORDER BY row_count DESC
        LIMIT 10
    """)

    # Check that channels are reasonable (not garbage from incorrect parsing)
    invalid_channels = 0
    for channel, medium, campaign, count in sample:
        if channel and ('_' in channel or '-' in channel):
            if len(channel.split('_')) > 2 or len(channel.split('-')) > 2:
                invalid_channels += 1

    require(invalid_channels < len(sample) * 0.5,
            f"Too many channels look like parsing artifacts: {invalid_channels}/{len(sample)}")

    # Check that 'direct' is used for NULL sources
    direct_count = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_attribution_fixed
        WHERE channel = 'direct'
    """))

    require(direct_count > 0, "Should have some 'direct' channel entries for NULL utm_source")

    print("UTM extraction validated")


def test_conversion_logic(setup_and_connection):
    """Test 5: Validate conversion counting is correct."""
    conn, db_type = setup_and_connection

    # Get total conversions from source
    # Use UPPER(CAST(...)) pattern for cross-DB boolean comparison
    # Use data-relative date filter (last 90 days from max date in source)
    source_conversions = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT session_id)
        FROM {SOURCE_SCHEMA}.stg_ga__sessions
        WHERE UPPER(CAST(is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
          AND CAST(session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {SOURCE_SCHEMA}.stg_ga__sessions) - interval '90 days'
    """))

    # Get total conversions from result
    result_conversions = int(execute_scalar(conn, db_type, f"""
        SELECT SUM(conversions)
        FROM {SCHEMA}.rpt_attribution_fixed
    """))

    # Allow some variance due to date filtering and NULL handling
    variance = abs(source_conversions - result_conversions) / max(source_conversions, 1)
    require(variance < 0.05,
            f"Conversion count mismatch: source={source_conversions}, result={result_conversions}, variance={variance:.2%}")

    print(f"Conversion logic validated (source: {source_conversions}, result: {result_conversions})")


def test_aggregation(setup_and_connection):
    """Test 6: Validate sessions are counted correctly (no double-counting from join fanout)."""
    conn, db_type = setup_and_connection

    source_sessions = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT session_id)
        FROM {SOURCE_SCHEMA}.stg_ga__sessions
        WHERE CAST(session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {SOURCE_SCHEMA}.stg_ga__sessions) - interval '90 days'
          AND session_id IS NOT NULL
    """))

    result_sessions = int(execute_scalar(conn, db_type, f"""
        SELECT SUM(sessions)
        FROM {SCHEMA}.rpt_attribution_fixed
    """))

    # Allow small variance for NULL handling
    variance = abs(source_sessions - result_sessions) / max(source_sessions, 1)
    require(variance < 0.02,
            f"Session count mismatch: source={source_sessions}, result={result_sessions}, variance={variance:.2%}")

    print(f"Aggregation validated (source: {source_sessions}, result: {result_sessions})")


def test_date_filter(setup_and_connection):
    """Test 7: Validate date filtering is correct (last 90 days relative to max date in source)."""
    conn, db_type = setup_and_connection

    min_date = execute_scalar(conn, db_type, f"""
        SELECT MIN(attribution_date)
        FROM {SCHEMA}.rpt_attribution_fixed
    """)

    max_date = execute_scalar(conn, db_type, f"""
        SELECT MAX(attribution_date)
        FROM {SCHEMA}.rpt_attribution_fixed
    """)

    # Get the max session date from source to compute expected bounds
    from datetime import datetime, timedelta
    source_max_date = execute_scalar(conn, db_type, f"""
        SELECT MAX(CAST(session_start AS DATE))
        FROM {SOURCE_SCHEMA}.stg_ga__sessions
    """)

    if hasattr(source_max_date, 'date'):
        source_max_date = source_max_date.date()

    ninety_days_before_max = source_max_date - timedelta(days=90)

    if min_date:
        # Handle potential date type differences
        if hasattr(min_date, 'date'):
            min_date = min_date.date()
        require(min_date >= ninety_days_before_max,
                f"Min date {min_date} is before 90 days before max source date {ninety_days_before_max}")
    if max_date:
        if hasattr(max_date, 'date'):
            max_date = max_date.date()
        require(max_date <= source_max_date,
                f"Max date {max_date} is after max source date {source_max_date}")

    print(f"Date filter validated (range: {min_date} to {max_date}, source max: {source_max_date})")


def test_revenue_attribution(setup_and_connection):
    """Test 8: Validate that attributed_revenue matches source event data."""
    conn, db_type = setup_and_connection

    # Get total revenue from source events (where conversion occurred)
    # Use data-relative date filter (last 90 days from max date in source)
    try:
        source_revenue = execute_scalar(conn, db_type, f"""
            SELECT COALESCE(SUM(CAST(t2_event_value AS DECIMAL(12,2))), 0)
            FROM {SOURCE_SCHEMA}.int_sessions_events_joined j
            JOIN {SOURCE_SCHEMA}.stg_ga__sessions s ON j.session_id = s.session_id
            WHERE UPPER(CAST(s.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
              AND j.t2_event_name = 'purchase'
              AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {SOURCE_SCHEMA}.stg_ga__sessions) - interval '90 days'
              AND j.t2_event_value IS NOT NULL
        """)
        source_revenue = float(source_revenue or 0)
    except Exception:
        source_revenue = 0.0

    # Get total revenue from result
    result_revenue = float(execute_scalar(conn, db_type, f"""
        SELECT COALESCE(SUM(attributed_revenue), 0)
        FROM {SCHEMA}.rpt_attribution_fixed
    """) or 0)

    # Allow small variance for rounding and NULL handling (within 1%)
    if source_revenue > 0:
        variance = abs(source_revenue - result_revenue) / source_revenue
        require(variance < 0.01,
                f"Revenue mismatch: source={source_revenue:.2f}, result={result_revenue:.2f}, variance={variance:.2%}")
    else:
        require(result_revenue < 1.0,
                f"Expected zero revenue but got {result_revenue:.2f}")

    print(f"Revenue attribution validated (source: {source_revenue:.2f}, result: {result_revenue:.2f})")


def test_channel_distribution(setup_and_connection):
    """Test 9: Validate that channel distribution is reasonable (no single channel dominates >95%)."""
    conn, db_type = setup_and_connection

    total_sessions = float(execute_scalar(conn, db_type, f"""
        SELECT SUM(sessions)
        FROM {SCHEMA}.rpt_attribution_fixed
    """) or 0)

    if total_sessions == 0:
        print("Skipping channel distribution test (no sessions)")
        return

    # Get channel distribution
    channel_dist = execute_query(conn, db_type, f"""
        SELECT
            channel,
            SUM(sessions) as channel_sessions
        FROM {SCHEMA}.rpt_attribution_fixed
        GROUP BY channel
        ORDER BY channel_sessions DESC
    """)

    # Calculate percentages
    channel_pcts = [(ch, float(sess), (float(sess) / total_sessions * 100) if total_sessions > 0 else 0)
                     for ch, sess in channel_dist]

    # Check that no single channel has >95% of sessions
    max_pct = max([pct for _, _, pct in channel_pcts]) if channel_pcts else 0
    require(max_pct <= 95.0,
            f"Single channel has {max_pct}% of sessions, indicating potential data issue")

    # Check that we have at least 2 different channels
    unique_channels = len(channel_pcts)
    if unique_channels == 1:
        channel_name = channel_pcts[0][0]
        require(channel_name == 'direct',
                f"Only one channel found ({channel_name}), expected at least 'direct' or multiple channels")

    print(f"Channel distribution validated ({unique_channels} channels, max: {max_pct:.1f}%)")


def test_conversion_rate_bounds(setup_and_connection):
    """Test 10: Validate conversion rates are within reasonable bounds per channel."""
    conn, db_type = setup_and_connection

    channel_rates = execute_query(conn, db_type, f"""
        SELECT
            channel,
            SUM(sessions) as total_sessions,
            SUM(conversions) as total_conversions,
            MIN(conversion_rate) as min_rate,
            MAX(conversion_rate) as max_rate
        FROM {SCHEMA}.rpt_attribution_fixed
        GROUP BY channel
        HAVING SUM(sessions) > 0
    """)

    for channel, sessions, conversions, min_rate, max_rate in channel_rates:
        sessions = float(sessions)
        conversions = float(conversions)
        min_rate = float(min_rate)
        max_rate = float(max_rate)

        require(0.0 <= min_rate <= 1.0,
                f"Channel {channel} has invalid min conversion_rate: {min_rate}")
        require(0.0 <= max_rate <= 1.0,
                f"Channel {channel} has invalid max conversion_rate: {max_rate}")

        if sessions > 0:
            expected_rate = round(conversions / sessions, 4)
            require(0.0 <= expected_rate <= 1.0,
                    f"Channel {channel} has invalid weighted conversion_rate: {expected_rate}")

    print(f"Conversion rate bounds validated ({len(channel_rates)} channels)")


def test_matches_source_reconciliation(setup_and_connection):
    """
    Test 13 (hard): Reconcile output vs. source by recomputing the same aggregation directly from source tables.
    """
    conn, db_type = setup_and_connection

    # Compute expected aggregation from source tables.
    # Use UPPER(CAST(...)) for cross-DB boolean handling
    # Use data-relative date filter (last 90 days from max date in source)
    expected = execute_query(conn, db_type, f"""
        WITH max_date_cte AS (
            SELECT MAX(CAST(session_start AS DATE)) AS max_date
            FROM {SOURCE_SCHEMA}.stg_ga__sessions
        ),
        sessions_base AS (
            SELECT DISTINCT
                s.session_id,
                CAST(s.session_start AS DATE) AS attribution_date,
                COALESCE(s.utm_source, 'direct') AS channel,
                COALESCE(s.utm_medium, 'none') AS medium,
                COALESCE(s.utm_campaign, 'none') AS campaign,
                s.is_converted AS is_converted,
                s.session_start
            FROM {SOURCE_SCHEMA}.stg_ga__sessions s
            CROSS JOIN max_date_cte md
            WHERE s.session_id IS NOT NULL
              AND s.session_start IS NOT NULL
              AND CAST(s.session_start AS DATE) >= md.max_date - interval '90 days'
        ),
        conversion_revenue AS (
            SELECT
                e.session_id,
                ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
            FROM {SOURCE_SCHEMA}.stg_ga__events e
            JOIN {SOURCE_SCHEMA}.stg_ga__sessions s
              ON e.session_id = s.session_id
            CROSS JOIN max_date_cte md
            WHERE UPPER(CAST(s.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
              AND CAST(s.session_start AS DATE) >= md.max_date - interval '90 days'
              AND e.event_name = 'purchase'
              AND e.event_value IS NOT NULL
            GROUP BY e.session_id
        )
        SELECT
            sb.attribution_date,
            sb.channel,
            sb.medium,
            sb.campaign,
            CAST(COUNT(DISTINCT sb.session_id) AS BIGINT) AS sessions,
            CAST(SUM(CASE WHEN UPPER(CAST(sb.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') THEN 1 ELSE 0 END) AS BIGINT) AS conversions,
            CAST(ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
            CAST(
                CASE
                    WHEN COUNT(DISTINCT sb.session_id) > 0 THEN
                        ROUND(
                            CAST(SUM(CASE WHEN UPPER(CAST(sb.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') THEN 1 ELSE 0 END) AS DECIMAL(18,8)) /
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

    actual = execute_query(conn, db_type, f"""
        SELECT
            attribution_date,
            channel,
            medium,
            campaign,
            CAST(sessions AS BIGINT) AS sessions,
            CAST(conversions AS BIGINT) AS conversions,
            CAST(attributed_revenue AS DECIMAL(12,2)) AS attributed_revenue,
            CAST(conversion_rate AS DECIMAL(10,4)) AS conversion_rate
        FROM {SCHEMA}.rpt_attribution_fixed
    """)

    # Compare sets (order-insensitive) with exact matching on all fields.
    # Convert to comparable tuples - handle Decimal types from Snowflake
    import datetime
    import decimal

    def normalize_val(v):
        if v is None:
            return None
        if isinstance(v, (datetime.date, datetime.datetime)):
            # Normalize to string for consistent comparison
            if isinstance(v, datetime.datetime):
                return str(v.date())
            return str(v)
        if isinstance(v, decimal.Decimal):
            return float(v)
        if isinstance(v, (int, float)):
            return float(v)
        return v

    def normalize_row(row):
        return tuple(normalize_val(v) for v in row)

    exp_set = set(normalize_row(r) for r in expected)
    act_set = set(normalize_row(r) for r in actual)

    missing = list(exp_set - act_set)
    extra = list(act_set - exp_set)

    require(len(missing) == 0, f"Output is missing {len(missing)} expected rows (sample: {missing[:3]})")
    require(len(extra) == 0, f"Output has {len(extra)} extra unexpected rows (sample: {extra[:3]})")

    print(f"Source reconciliation validated ({len(actual)} rows matched)")


def test_date_continuity(setup_and_connection):
    """Test 11: Validate there are no large gaps in dates (data quality check)."""
    conn, db_type = setup_and_connection

    date_counts = execute_query(conn, db_type, f"""
        SELECT
            attribution_date,
            COUNT(*) as row_count,
            SUM(sessions) as daily_sessions
        FROM {SCHEMA}.rpt_attribution_fixed
        GROUP BY attribution_date
        ORDER BY attribution_date
    """)

    if len(date_counts) < 2:
        print("Skipping date continuity test (insufficient dates)")
        return

    # Check for large gaps (more than 7 days between consecutive dates)
    from datetime import datetime, timedelta
    gaps = []
    for i in range(len(date_counts) - 1):
        date1 = date_counts[i][0]
        date2 = date_counts[i + 1][0]
        if date1 and date2:
            # Handle potential datetime vs date differences
            if hasattr(date1, 'date'):
                date1 = date1.date()
            if hasattr(date2, 'date'):
                date2 = date2.date()
            gap_days = (date2 - date1).days
            if gap_days > 7:
                gaps.append((date1, date2, gap_days))

    # Allow some gaps (weekends, holidays) but flag very large ones
    large_gaps = [g for g in gaps if g[2] > 14]
    require(len(large_gaps) == 0,
            f"Found {len(large_gaps)} large date gaps (>14 days): {large_gaps[:3]}")

    print(f"Date continuity validated ({len(date_counts)} unique dates)")


def test_revenue_precision(setup_and_connection):
    """Test 12: Validate revenue values are properly formatted and precise."""
    conn, db_type = setup_and_connection

    # Check for negative revenue
    negative_revenue = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_attribution_fixed
        WHERE attributed_revenue < 0
    """))

    require(negative_revenue == 0,
            f"Found {negative_revenue} rows with negative attributed_revenue")

    # Check that revenue is properly rounded (should have at most 2 decimal places)
    precision_issues = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_attribution_fixed
        WHERE attributed_revenue != ROUND(attributed_revenue, 2)
    """))

    require(precision_issues == 0,
            f"Found {precision_issues} rows with revenue precision issues")

    # Check that revenue is 0 when conversions are 0
    revenue_without_conversions = int(execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {SCHEMA}.rpt_attribution_fixed
        WHERE conversions = 0 AND attributed_revenue > 0
    """))

    if revenue_without_conversions > 0:
        print(f"Found {revenue_without_conversions} rows with revenue but no conversions (may be valid)")

    print("Revenue precision validated")
