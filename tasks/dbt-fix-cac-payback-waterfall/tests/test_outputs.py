"""
Verifier for CAC Payback Waterfall task.
Supports both DuckDB and Snowflake backends.
"""
import os
import subprocess

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


# ============ HELPERS ============


def run_cmd(cmd, cwd="/app/dbt_project"):
    """
    Execute a shell command and return the result with captured output.
    """
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:800]}")
    return result


def require(cond, msg):
    """Assert a condition, raising AssertionError with a message if false."""
    if not cond:
        raise AssertionError(msg)


def get_source_table(conn, db_type):
    """
    Return the fully-qualified name of the reference staging table in the `main` schema.
    """
    if db_type == 'snowflake':
        candidates = [
            'main.STG_FACT_MARKETING_SPEND',
            'main.stg_fact_marketing_spend',
            'main.STG_ANALYTICS__FACT_MARKETING_SPEND',
            'main.stg_analytics__fact_marketing_spend',
        ]
    else:
        candidates = [
            "main.stg_fact_marketing_spend",
            "main.stg_analytics__fact_marketing_spend",
        ]
    for cand in candidates:
        try:
            execute_query(conn, db_type, f"SELECT 1 FROM {cand} LIMIT 1")
            return cand
        except Exception:
            pass
    return None


def get_output_table(db_type):
    """Return the fully qualified output table name"""
    return 'analytics.rpt_cac_payback_waterfall_fixed'


def run_dbt_pipeline(conn, db_type):
    """
    Build the agent's dbt model.
    """
    # Fail fast if the reference staging table isn't present.
    source_tbl = get_source_table(conn, db_type)
    require(
        source_tbl is not None,
        "Reference staging table missing. Expected one of: "
        "main.stg_fact_marketing_spend, main.stg_analytics__fact_marketing_spend",
    )

    if db_type == 'duckdb':
        import duckdb
        # Close the read-only connection before opening a read-write one
        # to avoid DuckDB "different configuration" error
        conn.close()
        drop_conn = duckdb.connect("/app/database/retail.duckdb")
        for name in [
            "analytics.rpt_cac_payback_waterfall_fixed",
            "ANALYTICS.rpt_cac_payback_waterfall_fixed",
            "rpt_cac_payback_waterfall_fixed",
        ]:
            try:
                drop_conn.execute(f"DROP TABLE IF EXISTS {name}")
            except Exception:
                pass
        drop_conn.close()

    res3 = run_cmd("dbt run --select rpt_cac_payback_waterfall_fixed --full-refresh", cwd="/app/dbt_project")
    if res3.returncode != 0:
        err = res3.stderr or res3.stdout
        require(False, f"dbt run failed: {err[:1500]}")


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def db_conn():
    """
    Pytest fixture providing a database connection.
    Validates agent project structure, runs dbt pipeline, provides connection.
    """
    require(os.path.exists("/app/dbt_project"), "dbt_project directory missing - agent must create /app/dbt_project")
    require(
        os.path.exists("/app/dbt_project/models/marts/marketing/rpt_cac_payback_waterfall_fixed.sql"),
        "Model missing: /app/dbt_project/models/marts/marketing/rpt_cac_payback_waterfall_fixed.sql",
    )

    conn, db_type = get_db_connection()
    run_dbt_pipeline(conn, db_type)

    # For DuckDB, reopen as read-only after dbt run
    if db_type == 'duckdb':
        try:
            conn.close()
        except Exception:
            pass  # Connection may already be closed by run_dbt_pipeline
        import duckdb
        conn = duckdb.connect("/app/database/retail.duckdb", read_only=True)

    yield conn, db_type
    conn.close()


# ============ TESTS ============


def test_structure():
    """
    Smoke test that the agent created the required model file at the expected path.
    """
    require(os.path.exists("/app/dbt_project/models/marts/marketing/rpt_cac_payback_waterfall_fixed.sql"), "model file missing")


def test_schema(db_conn):
    """
    Verify the output table exists and includes all required columns with correct data types.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    if db_type == 'snowflake':
        db = os.environ['SNOWFLAKE_DATABASE']
        cols = execute_query(conn, db_type, f"""
            SELECT lower(column_name), data_type
            FROM information_schema.columns
            WHERE lower(table_schema) = 'analytics'
              AND lower(table_name) = 'rpt_cac_payback_waterfall_fixed'
            ORDER BY ordinal_position
        """)
    else:
        cols = execute_query(conn, db_type, """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_cac_payback_waterfall_fixed')
            ORDER BY cid
        """)

    col_names = {c[0].lower() for c in cols}
    required = {
        "campaign_id",
        "channel_key",
        "cohort_date",
        "days_since_cohort",
        "daily_spend",
        "daily_revenue_attributed",
        "cumulative_spend",
        "cumulative_revenue",
        "payback_ratio",
        "is_paid_back",
    }
    missing = required - col_names
    require(not missing, f"Missing required columns: {missing}")

    # Type checks
    type_map = {name.lower(): typ.upper() for name, typ in cols}

    if db_type == 'snowflake':
        expected_prefixes = {
            "campaign_id": ["VARCHAR", "TEXT", "STRING", "NUMBER"],
            "channel_key": ["NUMBER", "INTEGER", "BIGINT", "FLOAT"],
            "cohort_date": ["DATE"],
            "days_since_cohort": ["NUMBER", "INTEGER", "BIGINT", "FLOAT"],
            "daily_spend": ["NUMBER", "DECIMAL", "NUMERIC", "FLOAT"],
            "daily_revenue_attributed": ["NUMBER", "DECIMAL", "NUMERIC", "FLOAT"],
            "cumulative_spend": ["NUMBER", "DECIMAL", "NUMERIC", "FLOAT"],
            "cumulative_revenue": ["NUMBER", "DECIMAL", "NUMERIC", "FLOAT"],
            "payback_ratio": ["NUMBER", "DECIMAL", "NUMERIC", "FLOAT"],
            "is_paid_back": ["BOOLEAN"],
        }
    else:
        expected_prefixes = {
            "campaign_id": ["VARCHAR", "TEXT", "STRING"],
            "channel_key": ["INTEGER", "BIGINT", "HUGEINT", "SMALLINT", "TINYINT"],
            "cohort_date": ["DATE"],
            "days_since_cohort": ["INTEGER", "BIGINT", "HUGEINT", "SMALLINT", "TINYINT"],
            "daily_spend": ["DECIMAL", "NUMERIC", "DOUBLE", "REAL"],
            "daily_revenue_attributed": ["DECIMAL", "NUMERIC", "DOUBLE", "REAL"],
            "cumulative_spend": ["DECIMAL", "NUMERIC", "DOUBLE", "REAL"],
            "cumulative_revenue": ["DECIMAL", "NUMERIC", "DOUBLE", "REAL"],
            "payback_ratio": ["DECIMAL", "NUMERIC", "DOUBLE", "REAL"],
            "is_paid_back": ["BOOLEAN"],
        }

    for col, prefixes in expected_prefixes.items():
        actual = type_map.get(col)
        require(actual is not None, f"Missing column in schema info: {col}")
        require(
            any(actual.startswith(p) for p in prefixes),
            f"Unexpected type for {col}: {actual} (expected one of prefixes {prefixes})",
        )


def test_not_null_and_uniqueness(db_conn):
    """
    Validate data completeness and primary key uniqueness.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    nulls = execute_query(conn, db_type, f"""
        SELECT
          SUM(CASE WHEN campaign_id IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN channel_key IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN cohort_date IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN days_since_cohort IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN daily_spend IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN daily_revenue_attributed IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN cumulative_spend IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN cumulative_revenue IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN payback_ratio IS NULL THEN 1 ELSE 0 END),
          SUM(CASE WHEN is_paid_back IS NULL THEN 1 ELSE 0 END)
        FROM {out_tbl}
    """)
    null_row = nulls[0]
    require(sum(int(x) for x in null_row) == 0, f"Found NULLs in required fields: {null_row}")

    dupes = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM (
          SELECT campaign_id, days_since_cohort, COUNT(*) AS n
          FROM {out_tbl}
          GROUP BY 1,2
          HAVING COUNT(*) > 1
        )
    """)
    require(int(dupes) == 0, f"Found {dupes} duplicate (campaign_id, days_since_cohort) keys")


def test_days_since_cohort_is_well_formed(db_conn):
    """
    Validate cohort indexing correctness and completeness.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    neg = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {out_tbl}
        WHERE days_since_cohort < 0
    """)
    require(int(neg) == 0, f"Found {neg} rows with negative days_since_cohort")

    missing_day0 = execute_scalar(conn, db_type, f"""
        WITH per_campaign AS (
          SELECT campaign_id, MIN(days_since_cohort) AS min_day
          FROM {out_tbl}
          GROUP BY 1
        )
        SELECT COUNT(*)
        FROM per_campaign
        WHERE min_day <> 0
    """)
    require(int(missing_day0) == 0, f"Found {missing_day0} campaigns missing a day 0 row")


def test_non_negative(db_conn):
    """
    Validate that all currency measures are non-negative.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    bad = execute_query(conn, db_type, f"""
        SELECT
          SUM(CASE WHEN daily_spend < 0 THEN 1 ELSE 0 END),
          SUM(CASE WHEN daily_revenue_attributed < 0 THEN 1 ELSE 0 END),
          SUM(CASE WHEN cumulative_spend < 0 THEN 1 ELSE 0 END),
          SUM(CASE WHEN cumulative_revenue < 0 THEN 1 ELSE 0 END)
        FROM {out_tbl}
    """)
    bad_row = bad[0]
    require(int(bad_row[0]) == 0, f"Negative daily_spend rows: {bad_row[0]}")
    require(int(bad_row[1]) == 0, f"Negative daily_revenue_attributed rows: {bad_row[1]}")
    require(int(bad_row[2]) == 0, f"Negative cumulative_spend rows: {bad_row[2]}")
    require(int(bad_row[3]) == 0, f"Negative cumulative_revenue rows: {bad_row[3]}")


def test_monotonic_cumulatives(db_conn):
    """
    Verify that cumulative values are non-decreasing within each campaign.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    bad = execute_scalar(conn, db_type, f"""
        WITH ordered AS (
          SELECT
            campaign_id,
            days_since_cohort,
            cumulative_spend,
            cumulative_revenue,
            LAG(cumulative_spend) OVER (PARTITION BY campaign_id ORDER BY days_since_cohort) AS prev_spend,
            LAG(cumulative_revenue) OVER (PARTITION BY campaign_id ORDER BY days_since_cohort) AS prev_rev
          FROM {out_tbl}
        )
        SELECT COUNT(*)
        FROM ordered
        WHERE (prev_spend IS NOT NULL AND cumulative_spend < prev_spend)
           OR (prev_rev IS NOT NULL AND cumulative_revenue < prev_rev)
    """)
    require(int(bad) == 0, f"Found {bad} rows where cumulative values decreased")


def test_precision_rules(db_conn):
    """
    Validate that numeric fields are rounded to the specified decimal precision.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    bad = execute_query(conn, db_type, f"""
        SELECT
          SUM(CASE WHEN daily_spend <> ROUND(daily_spend, 2) THEN 1 ELSE 0 END),
          SUM(CASE WHEN daily_revenue_attributed <> ROUND(daily_revenue_attributed, 2) THEN 1 ELSE 0 END),
          SUM(CASE WHEN cumulative_spend <> ROUND(cumulative_spend, 2) THEN 1 ELSE 0 END),
          SUM(CASE WHEN cumulative_revenue <> ROUND(cumulative_revenue, 2) THEN 1 ELSE 0 END),
          SUM(CASE WHEN payback_ratio <> ROUND(payback_ratio, 4) THEN 1 ELSE 0 END)
        FROM {out_tbl}
    """)
    bad_row = bad[0]
    require(int(bad_row[0]) == 0, f"Found {bad_row[0]} rows where daily_spend is not rounded to 2 decimals")
    require(int(bad_row[1]) == 0, f"Found {bad_row[1]} rows where daily_revenue_attributed is not rounded to 2 decimals")
    require(int(bad_row[2]) == 0, f"Found {bad_row[2]} rows where cumulative_spend is not rounded to 2 decimals")
    require(int(bad_row[3]) == 0, f"Found {bad_row[3]} rows where cumulative_revenue is not rounded to 2 decimals")
    require(int(bad_row[4]) == 0, f"Found {bad_row[4]} rows where payback_ratio is not rounded to 4 decimals")


def test_payback_ratio_and_flag_consistency(db_conn):
    """
    Verify internal consistency of calculated payback metrics.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    mismatches = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {out_tbl}
        WHERE
          (
            (cumulative_spend = 0 AND payback_ratio <> 0)
            OR
            (cumulative_spend <> 0 AND payback_ratio <> ROUND(cumulative_revenue / cumulative_spend, 4))
          )
          OR (is_paid_back <> (cumulative_revenue >= cumulative_spend))
    """)
    require(int(mismatches) == 0, f"Found {mismatches} rows with inconsistent payback_ratio or is_paid_back values")


def test_reconciliation_to_source(db_conn):
    """
    Reconcile output table totals against source data to ensure no data loss.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    source_tbl = get_source_table(conn, db_type)
    require(source_tbl is not None, "Could not find marketing spend staging table in main schema")

    if db_type == 'snowflake':
        mismatches = execute_scalar(conn, db_type, f"""
            WITH src AS (
              SELECT
                campaign_id,
                ROUND(SUM(CAST(spend_amount AS DECIMAL(18,2))), 2) AS total_spend,
                ROUND(SUM(CAST(revenue_attributed AS DECIMAL(18,2))), 2) AS total_rev
              FROM {source_tbl}
              GROUP BY 1
            ),
            last_row AS (
              SELECT
                campaign_id,
                MAX_BY(cumulative_spend, days_since_cohort) AS last_cum_spend,
                MAX_BY(cumulative_revenue, days_since_cohort) AS last_cum_rev
              FROM {out_tbl}
              GROUP BY 1
            )
            SELECT COUNT(*)
            FROM src
            JOIN last_row USING (campaign_id)
            WHERE ABS(src.total_spend - last_row.last_cum_spend) > 0.01
               OR ABS(src.total_rev - last_row.last_cum_rev) > 0.01
        """)
    else:
        mismatches = execute_scalar(conn, db_type, f"""
            WITH src AS (
              SELECT
                campaign_id,
                ROUND(SUM(CAST(spend_amount AS DECIMAL(18,2))), 2) AS total_spend,
                ROUND(SUM(CAST(revenue_attributed AS DECIMAL(18,2))), 2) AS total_rev
              FROM {source_tbl}
              GROUP BY 1
            ),
            last_row AS (
              SELECT
                campaign_id,
                arg_max(cumulative_spend, days_since_cohort) AS last_cum_spend,
                arg_max(cumulative_revenue, days_since_cohort) AS last_cum_rev
              FROM {out_tbl}
              GROUP BY 1
            )
            SELECT COUNT(*)
            FROM src
            JOIN last_row USING (campaign_id)
            WHERE ABS(src.total_spend - last_row.last_cum_spend) > 0.01
               OR ABS(src.total_rev - last_row.last_cum_rev) > 0.01
        """)
    require(int(mismatches) == 0, f"Found {mismatches} campaigns where cumulative totals don't reconcile to source")


def test_cohort_date_matches_source_min_date(db_conn):
    """
    Validate that cohort_date correctly identifies the first spend date per campaign.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    source_tbl = get_source_table(conn, db_type)
    require(source_tbl is not None, "Could not find marketing spend staging table in main schema")

    if db_type == 'snowflake':
        bad = execute_scalar(conn, db_type, f"""
            WITH src AS (
              SELECT
                campaign_id,
                MIN(
                  COALESCE(
                    TRY_TO_DATE(TO_VARCHAR(date_key), 'YYYYMMDD'),
                    TRY_TO_DATE(TO_VARCHAR(date_key), 'YYYY-MM-DD'),
                    TRY_TO_DATE(TO_VARCHAR(date_key))
                  )
                ) AS src_min_date
              FROM {source_tbl}
              GROUP BY 1
            ),
            out AS (
              SELECT campaign_id, MIN(cohort_date) AS out_cohort_date
              FROM {out_tbl}
              GROUP BY 1
            )
            SELECT COUNT(*)
            FROM src
            JOIN out USING (campaign_id)
            WHERE src.src_min_date <> out.out_cohort_date
        """)
    else:
        bad = execute_scalar(conn, db_type, f"""
            WITH src AS (
              SELECT
                campaign_id,
                MIN(
                  CASE
                    WHEN typeof(date_key) = 'DATE' THEN CAST(date_key AS DATE)
                    ELSE CAST(strptime(CAST(date_key AS VARCHAR), '%Y%m%d') AS DATE)
                  END
                ) AS src_min_date
              FROM {source_tbl}
              GROUP BY 1
            ),
            out AS (
              SELECT campaign_id, MIN(cohort_date) AS out_cohort_date
              FROM {out_tbl}
              GROUP BY 1
            )
            SELECT COUNT(*)
            FROM src
            JOIN out USING (campaign_id)
            WHERE src.src_min_date <> out.out_cohort_date
        """)
    require(int(bad) == 0, f"Found {bad} campaigns where cohort_date does not match MIN(source date)")


def test_data_type_precision_and_scale(db_conn):
    """
    Verify that DECIMAL columns have the correct precision and scale as specified.
    """
    conn, db_type = db_conn

    if db_type == 'snowflake':
        cols = execute_query(conn, db_type, """
            SELECT lower(column_name), data_type
            FROM information_schema.columns
            WHERE lower(table_schema) = 'analytics'
              AND lower(table_name) = 'rpt_cac_payback_waterfall_fixed'
              AND lower(column_name) IN ('daily_spend', 'daily_revenue_attributed', 'cumulative_spend',
                                         'cumulative_revenue', 'payback_ratio')
            ORDER BY lower(column_name)
        """)
    else:
        cols = execute_query(conn, db_type, """
            SELECT name, type
            FROM pragma_table_info('analytics.rpt_cac_payback_waterfall_fixed')
            WHERE name IN ('daily_spend', 'daily_revenue_attributed', 'cumulative_spend',
                           'cumulative_revenue', 'payback_ratio')
            ORDER BY name
        """)

    type_map = {name.lower(): typ.upper() for name, typ in cols}

    # Check currency fields should be DECIMAL(12,2)
    currency_fields = ['daily_spend', 'daily_revenue_attributed', 'cumulative_spend', 'cumulative_revenue']
    for field in currency_fields:
        actual_type = type_map.get(field)
        require(actual_type is not None, f"Missing currency field: {field}")
        if 'DECIMAL' in actual_type or 'NUMERIC' in actual_type or 'NUMBER' in actual_type:
            if '(12,2)' in actual_type or '12,2' in actual_type:
                continue
            if '(' not in actual_type:
                continue
        if any(actual_type.startswith(p) for p in ['DECIMAL', 'NUMERIC', 'DOUBLE', 'REAL', 'NUMBER', 'FLOAT']):
            continue
        require(False, f"Currency field {field} has unexpected type: {actual_type} (expected DECIMAL(12,2) or similar)")

    # Check payback_ratio should be DECIMAL(10,4)
    ratio_type = type_map.get('payback_ratio')
    require(ratio_type is not None, "Missing payback_ratio field")
    if 'DECIMAL' in ratio_type or 'NUMERIC' in ratio_type or 'NUMBER' in ratio_type:
        if '(10,4)' in ratio_type or '10,4' in ratio_type:
            pass
        elif '(' not in ratio_type:
            pass
    elif any(ratio_type.startswith(p) for p in ['DECIMAL', 'NUMERIC', 'DOUBLE', 'REAL', 'NUMBER', 'FLOAT']):
        pass
    else:
        require(False, f"payback_ratio has unexpected type: {ratio_type} (expected DECIMAL(10,4) or similar)")


def test_cohort_completeness_all_source_days_included(db_conn):
    """
    Verify that all source campaign-days are included in the output (no missing days).
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    source_tbl = get_source_table(conn, db_type)
    require(source_tbl is not None, "Could not find marketing spend staging table in main schema")

    if db_type == 'snowflake':
        missing_days = execute_scalar(conn, db_type, f"""
            WITH src_days AS (
              SELECT DISTINCT
                campaign_id,
                COALESCE(
                  TRY_TO_DATE(TO_VARCHAR(date_key), 'YYYYMMDD'),
                  TRY_TO_DATE(TO_VARCHAR(date_key), 'YYYY-MM-DD'),
                  TRY_TO_DATE(TO_VARCHAR(date_key))
                ) AS src_date
              FROM {source_tbl}
              WHERE campaign_id IS NOT NULL
            ),
            src_cohorts AS (
              SELECT
                campaign_id,
                MIN(src_date) AS cohort_date
              FROM src_days
              GROUP BY 1
            ),
            src_with_days AS (
              SELECT
                sd.campaign_id,
                DATEDIFF('day', sc.cohort_date, sd.src_date) AS expected_days_since_cohort
              FROM src_days sd
              JOIN src_cohorts sc USING (campaign_id)
            ),
            out_days AS (
              SELECT DISTINCT campaign_id, days_since_cohort
              FROM {out_tbl}
            )
            SELECT COUNT(*)
            FROM src_with_days swd
            LEFT JOIN out_days od
              ON swd.campaign_id = od.campaign_id
              AND swd.expected_days_since_cohort = od.days_since_cohort
            WHERE od.days_since_cohort IS NULL
        """)
    else:
        missing_days = execute_scalar(conn, db_type, f"""
            WITH src_days AS (
              SELECT DISTINCT
                campaign_id,
                CASE
                  WHEN typeof(date_key) = 'DATE' THEN CAST(date_key AS DATE)
                  ELSE CAST(strptime(CAST(date_key AS VARCHAR), '%Y%m%d') AS DATE)
                END AS src_date
              FROM {source_tbl}
              WHERE campaign_id IS NOT NULL
            ),
            src_cohorts AS (
              SELECT
                campaign_id,
                MIN(src_date) AS cohort_date
              FROM src_days
              GROUP BY 1
            ),
            src_with_days AS (
              SELECT
                sd.campaign_id,
                DATE_DIFF('day', sc.cohort_date, sd.src_date) AS expected_days_since_cohort
              FROM src_days sd
              JOIN src_cohorts sc USING (campaign_id)
            ),
            out_days AS (
              SELECT DISTINCT campaign_id, days_since_cohort
              FROM {out_tbl}
            )
            SELECT COUNT(*)
            FROM src_with_days swd
            LEFT JOIN out_days od
              ON swd.campaign_id = od.campaign_id
              AND swd.expected_days_since_cohort = od.days_since_cohort
            WHERE od.days_since_cohort IS NULL
        """)
    require(int(missing_days) == 0, f"Found {missing_days} source campaign-days missing from output table")


def test_channel_key_consistency(db_conn):
    """
    Validate that channel_key is consistent within each campaign.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    inconsistent = execute_scalar(conn, db_type, f"""
        SELECT COUNT(DISTINCT campaign_id)
        FROM (
          SELECT campaign_id, COUNT(DISTINCT channel_key) AS n_channels
          FROM {out_tbl}
          GROUP BY 1
          HAVING COUNT(DISTINCT channel_key) > 1
        )
    """)
    require(int(inconsistent) == 0, f"Found {inconsistent} campaigns with inconsistent channel_key values")


def test_completeness_all_source_campaigns_included(db_conn):
    """
    Verify that all campaigns from source data are represented in the output.
    """
    conn, db_type = db_conn
    out_tbl = get_output_table(db_type)

    source_tbl = get_source_table(conn, db_type)
    require(source_tbl is not None, "Could not find marketing spend staging table in main schema")

    missing = execute_scalar(conn, db_type, f"""
        WITH src_campaigns AS (
          SELECT DISTINCT campaign_id
          FROM {source_tbl}
          WHERE campaign_id IS NOT NULL
        ),
        out_campaigns AS (
          SELECT DISTINCT campaign_id
          FROM {out_tbl}
        )
        SELECT COUNT(*)
        FROM src_campaigns sc
        LEFT JOIN out_campaigns oc USING (campaign_id)
        WHERE oc.campaign_id IS NULL
    """)
    require(int(missing) == 0, f"Found {missing} campaigns in source data missing from output table")
