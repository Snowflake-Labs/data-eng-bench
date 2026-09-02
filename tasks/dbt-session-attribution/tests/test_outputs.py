"""
Test Suite for Advanced Multi-Touch Attribution with Hybrid Decay Model

This module validates the dbt-generated attribution_report against a Python reference
implementation. It ensures the candidate's dbt solution correctly implements:

1. Hierarchical Channel Classification: Priority-based channel detection
2. Session Quality Filtering: Bounce, single-page, and bot filtering
3. Hybrid Decay Model: Combined time-decay and position-based weighting
4. Cross-Channel Bonus: Revenue multiplier for diverse conversion paths
5. Multi-Touch Attribution: Distributing conversion credit across eligible sessions
6. Aggregation: Summarizing total conversions and revenue by channel

Test Strategy:
- The reference implementation (calculate_expected_attribution) independently computes
  the expected output using the same database data and business rules
- The actual output is read from the candidate's database
- Results are compared with a tolerance of 0.05 for floating-point differences
"""

import pandas as pd
import numpy as np
import os
import subprocess

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

def execute_query_df(conn, db_type, query):
    """Execute a query and return a pandas DataFrame"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        cursor.execute(query)
        columns = [desc[0].lower() for desc in cursor.description]
        rows = cursor.fetchall()
        return pd.DataFrame(rows, columns=columns)
    else:
        result = conn.execute(query)
        return result.df()

def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')

# ============ REFERENCE IMPLEMENTATION ============

def calculate_expected_attribution():
    """
    Compute the expected attribution report using Python/Pandas as a reference.

    This function serves as the ground truth for validating the dbt solution.
    It implements all business rules from the task specification.

    Returns:
        pd.DataFrame: Expected attribution report with columns:
            - channel: Marketing channel name
            - total_conversions: Sum of fractional conversion credits per channel
            - total_revenue: Sum of attributed revenue per channel
    """

    # =========================================================================
    # DATA LOADING
    # =========================================================================
    conn, db_type = get_db_connection()

    # Load sessions from staging table
    sessions = execute_query_df(conn, db_type, """
        SELECT
            session_id,
            customer_id,
            session_start,
            referrer,
            utm_source,
            utm_medium,
            device_type,
            duration_seconds,
            page_views,
            is_converted,
            order_id
        FROM stg_digital__web_sessions
    """)

    sessions.columns = sessions.columns.str.lower()

    # Load sales/conversions from staging table
    sales = execute_query_df(conn, db_type, """
        SELECT
            order_id,
            total_amount as revenue
        FROM stg_analytics__fact_sales
        WHERE order_id IS NOT NULL
    """)

    sales.columns = sales.columns.str.lower()
    conn.close()

    sessions['session_start'] = pd.to_datetime(sessions['session_start'])

    # Convert numeric columns to float to handle Snowflake Decimal types
    sessions['duration_seconds'] = sessions['duration_seconds'].apply(lambda x: float(x) if x is not None else None)
    sessions['page_views'] = sessions['page_views'].apply(lambda x: int(x) if x is not None else None)
    sales['revenue'] = sales['revenue'].apply(lambda x: float(x) if x is not None else None)

    # Handle is_converted - Snowflake may store as VARCHAR
    def parse_bool(val):
        if val is None:
            return False
        if isinstance(val, bool):
            return val
        if isinstance(val, (int, float)):
            return bool(val)
        s = str(val).upper().strip()
        return s in ('1', 'TRUE', 'T', 'Y', 'YES')

    sessions['is_converted'] = sessions['is_converted'].apply(parse_bool)

    # =========================================================================
    # HIERARCHICAL CHANNEL CLASSIFICATION (Priority Order)
    # =========================================================================
    def get_channel(row):
        """Map session to marketing channel using hierarchical priority rules."""
        referrer = row['referrer'] if pd.notna(row['referrer']) else ''
        utm_source = row['utm_source'] if pd.notna(row['utm_source']) else ''
        utm_medium = row['utm_medium'] if pd.notna(row['utm_medium']) else ''

        referrer_lower = referrer.lower()
        utm_medium_lower = utm_medium.lower()

        # Priority 1: Paid Search
        if utm_medium_lower in ['cpc', 'ppc']:
            return 'Paid Search'

        # Priority 2: Paid Social
        if utm_medium_lower == 'paid_social' or ('facebook' in referrer_lower and utm_source != ''):
            return 'Paid Social'

        # Priority 3: Organic Search
        if any(engine in referrer_lower for engine in ['google', 'bing', 'yahoo']):
            return 'Organic Search'

        # Priority 4: Organic Social
        if any(social in referrer_lower for social in ['facebook', 'twitter', 'linkedin', 'instagram']):
            return 'Organic Social'

        # Priority 5: Email
        if utm_medium_lower == 'email' or 'mail' in referrer_lower:
            return 'Email'

        # Priority 6: Direct
        if referrer == '':
            return 'Direct'

        # Priority 7: Referral
        return 'Referral'

    sessions['channel'] = sessions.apply(get_channel, axis=1)

    # =========================================================================
    # SESSION QUALITY FILTERING
    # Exclude bounce sessions, single-page sessions, and bot traffic
    # =========================================================================
    quality_sessions = sessions[
        (sessions['duration_seconds'] >= 5) &
        (sessions['page_views'] >= 2) &
        (sessions['device_type'].str.lower() != 'bot')
    ].copy()

    # =========================================================================
    # BUILD CONVERSIONS
    # =========================================================================
    conversions_revenue = sales.groupby('order_id').agg(
        revenue=('revenue', 'sum')
    ).reset_index()

    converting_sessions = sessions[sessions['is_converted'] == True][['customer_id', 'order_id', 'session_start']].copy()
    converting_sessions = converting_sessions.rename(columns={'session_start': 'conversion_at'})

    conversions = pd.merge(
        converting_sessions,
        conversions_revenue,
        on='order_id',
        how='inner'
    )
    conversions = conversions.rename(columns={'order_id': 'conversion_id'})

    # =========================================================================
    # ATTRIBUTION WITH HYBRID DECAY MODEL
    # =========================================================================
    attribution_results = []

    for _, conv in conversions.iterrows():
        # Get quality-filtered sessions for the customer
        customer_sessions = quality_sessions[quality_sessions['customer_id'] == conv['customer_id']].copy()

        # 14-day lookback window
        cutoff_time = conv['conversion_at'] - pd.Timedelta(days=14)

        # Sessions strictly before conversion within lookback
        eligible_sessions = customer_sessions[
            (customer_sessions['session_start'] < conv['conversion_at']) &
            (customer_sessions['session_start'] >= cutoff_time)
        ].copy()

        if eligible_sessions.empty:
            continue

        # Sort by session_start to determine positions
        eligible_sessions = eligible_sessions.sort_values('session_start').reset_index(drop=True)
        num_sessions = len(eligible_sessions)

        # =====================================================================
        # POSITION-BASED WEIGHT
        # First touch: 1.5, Last touch: 1.3, Middle: 1.0
        # =====================================================================
        def get_position_multiplier(idx, total):
            if total == 1:
                return 1.0
            if idx == 0:  # First touch
                return 1.5
            if idx == total - 1:  # Last touch
                return 1.3
            return 1.0

        eligible_sessions['position_multiplier'] = [
            get_position_multiplier(i, num_sessions) for i in range(num_sessions)
        ]

        # =====================================================================
        # TIME-DECAY WEIGHT: e^(-t/7)
        # =====================================================================
        eligible_sessions['days_diff'] = (
            (conv['conversion_at'] - eligible_sessions['session_start']).dt.total_seconds() / 86400.0
        )
        eligible_sessions['time_weight'] = np.exp(-eligible_sessions['days_diff'] / 7.0)

        # =====================================================================
        # COMBINED WEIGHT
        # =====================================================================
        eligible_sessions['raw_weight'] = eligible_sessions['position_multiplier'] * eligible_sessions['time_weight']

        # =====================================================================
        # CROSS-CHANNEL BONUS
        # If >= 3 distinct channels, multiply revenue by 1.1
        # =====================================================================
        distinct_channels = eligible_sessions['channel'].nunique()
        revenue_multiplier = 1.1 if distinct_channels >= 3 else 1.0
        adjusted_revenue = float(conv['revenue']) * revenue_multiplier

        # =====================================================================
        # NORMALIZATION
        # =====================================================================
        total_weight = eligible_sessions['raw_weight'].sum()
        eligible_sessions['credit'] = eligible_sessions['raw_weight'] / total_weight
        eligible_sessions['attributed_revenue'] = eligible_sessions['credit'] * adjusted_revenue

        attribution_results.append(eligible_sessions[['channel', 'credit', 'attributed_revenue']])

    if not attribution_results:
        return pd.DataFrame(columns=['channel', 'total_conversions', 'total_revenue'])

    all_attribution = pd.concat(attribution_results)

    # =========================================================================
    # AGGREGATION BY CHANNEL
    # =========================================================================
    final = all_attribution.groupby('channel').agg(
        total_conversions=('credit', 'sum'),
        total_revenue=('attributed_revenue', 'sum')
    ).reset_index()

    final['total_conversions'] = final['total_conversions'].round(2)
    final['total_revenue'] = final['total_revenue'].round(2)

    return final.sort_values('channel').reset_index(drop=True)


def test_attribution_report():
    """
    Main test function: Validate the dbt-generated attribution_report.

    Test Steps:
    1. Verify the attribution_report table exists
    2. Load actual results from the candidate's dbt output
    3. Compute expected results using the reference implementation
    4. Compare channels: ensure no missing or extra channels
    5. Compare numeric values: allow tolerance of 0.05 for floating-point differences

    Raises:
        AssertionError: If the table is missing, channels don't match, or values differ
    """

    # =========================================================================
    # TABLE EXISTENCE CHECK (DYNAMIC)
    # Discover which schema contains the 'attribution_report' table instead of
    # relying on a hardcoded schema name.
    # =========================================================================
    conn, db_type = get_db_connection()

    _expected_schema = ('main').lower()
    schema_res = execute_query(conn, db_type, f"""
        SELECT table_schema
        FROM information_schema.tables
        WHERE lower(table_name) = 'attribution_report'
          AND lower(table_schema) = '{_expected_schema}'
        LIMIT 1
    """)

    if not schema_res:
        conn.close()
        raise AssertionError(
            "Table 'attribution_report' not found in the database. "
            "Ensure the model produced the table in the 'main' schema."
        )

    schema_name = schema_res[0][0]

    # =========================================================================
    # LOAD ACTUAL AND EXPECTED RESULTS
    # =========================================================================
    actual_df = execute_query_df(conn, db_type,
        f'SELECT * FROM "{schema_name}".attribution_report ORDER BY channel'
    )
    actual_df.columns = actual_df.columns.str.lower()
    conn.close()

    # Convert numeric columns to float for Snowflake Decimal compatibility
    actual_df['total_conversions'] = actual_df['total_conversions'].apply(lambda x: float(x) if x is not None else None)
    actual_df['total_revenue'] = actual_df['total_revenue'].apply(lambda x: float(x) if x is not None else None)

    # Compute expected results using reference implementation
    expected_df = calculate_expected_attribution()

    # =========================================================================
    # DIAGNOSTIC OUTPUT
    # Print both dataframes for debugging failed tests
    # =========================================================================
    print("=" * 60)
    print("EXPECTED RESULTS (Reference Implementation):")
    print("=" * 60)
    print(expected_df)
    print("\n" + "=" * 60)
    print("ACTUAL RESULTS (Candidate's dbt Output):")
    print("=" * 60)
    print(actual_df)
    print()

    # =========================================================================
    # COMPARISON: CHANNEL MATCHING
    # Use outer merge to detect missing or extra channels
    # =========================================================================
    merged = pd.merge(
        expected_df, actual_df,
        on='channel',
        suffixes=('_exp', '_act'),
        how='outer'
    )

    # Check for missing/extra channels (NaN values indicate mismatch)
    if merged.isnull().any().any():
        print("ERROR: Channel mismatch detected!")
        print("Merged comparison (NaN indicates missing data):")
        print(merged)
        raise AssertionError(
            "Channels do not match expected output. "
            "Check channel classification logic in the dbt model."
        )

    # =========================================================================
    # COMPARISON: NUMERIC VALUES
    # Allow tolerance of 0.05 for floating-point rounding differences
    # This accounts for minor differences in floating-point arithmetic
    # between SQL (DuckDB/Snowflake) and Python implementations
    # =========================================================================
    TOLERANCE = 0.05  # Acceptable difference threshold

    for col in ['total_conversions', 'total_revenue']:
        diff = np.abs(merged[f'{col}_exp'] - merged[f'{col}_act'])
        if (diff > TOLERANCE).any():
            print(f"ERROR: Value mismatch in '{col}'!")
            print("Comparison (channels where difference > tolerance):")
            mismatch_df = merged[['channel', f'{col}_exp', f'{col}_act']].copy()
            mismatch_df['difference'] = diff
            print(mismatch_df)
            raise AssertionError(
                f"Values for '{col}' exceed tolerance of {TOLERANCE}. "
                "Check time-decay calculation, attribution window, or aggregation logic."
            )

    # =========================================================================
    # SUCCESS
    # =========================================================================
    print("=" * 60)
    print("TEST PASSED: Attribution report matches expected output!")
    print("=" * 60)


if __name__ == "__main__":
    test_attribution_report()
