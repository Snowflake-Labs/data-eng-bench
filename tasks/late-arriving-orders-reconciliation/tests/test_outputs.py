"""
Test cases for Late-Arriving Orders Reconciliation.
Tests verify that adjustment entries are correctly generated for orders crossing GL period boundaries.
"""

import os
import subprocess
import pytest
import pandas as pd


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


# ============ END DUAL-BACKEND INFRASTRUCTURE ============


OUTPUT_FILE = "/app/late_orders_adjustments.csv"


@pytest.fixture
def output_df():
    """Load the output CSV file."""
    if not os.path.exists(OUTPUT_FILE):
        pytest.fail(f"Output file not found: {OUTPUT_FILE}")
    return pd.read_csv(OUTPUT_FILE)


@pytest.fixture
def db_conn():
    """Create database connection."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


class TestOutputFileStructure:
    """Test that output file has correct structure."""

    def test_output_file_exists(self):
        """Output file should exist."""
        assert os.path.exists(OUTPUT_FILE), f"Output file not found: {OUTPUT_FILE}"

    def test_required_columns_present(self, output_df):
        """Output should have all required columns."""
        required_columns = [
            'period_id',
            'period_name',
            'adjustment_type',
            'order_count',
            'original_amount_local',
            'adjusted_amount_usd',
            'variance_reason'
        ]
        for col in required_columns:
            assert col in output_df.columns, f"Missing required column: {col}"

    def test_output_not_empty(self, output_df):
        """Output should contain data."""
        assert len(output_df) > 0, "Output file is empty"

    def test_has_total_row(self, output_df):
        """Output should have a TOTAL summary row."""
        total_rows = output_df[output_df['period_id'] == 'TOTAL']
        assert len(total_rows) >= 1, "Missing TOTAL summary row"


class TestAdjustmentTypes:
    """Test that adjustment types are correct."""

    def test_valid_adjustment_types(self, output_df):
        """Adjustment types should be REVERSAL, RECOGNITION, or SUMMARY."""
        valid_types = {'REVERSAL', 'RECOGNITION', 'SUMMARY'}
        unique_types = set(output_df['adjustment_type'].unique())
        invalid_types = unique_types - valid_types
        assert len(invalid_types) == 0, f"Invalid adjustment types found: {invalid_types}"

    def test_has_reversal_entries(self, output_df):
        """Should have REVERSAL entries if there are late orders."""
        non_total = output_df[output_df['period_id'] != 'TOTAL']
        if len(non_total) > 0:
            reversals = non_total[non_total['adjustment_type'] == 'REVERSAL']
            assert len(reversals) > 0, "Missing REVERSAL entries for late orders"

    def test_has_recognition_entries(self, output_df):
        """Should have RECOGNITION entries if there are late orders."""
        non_total = output_df[output_df['period_id'] != 'TOTAL']
        if len(non_total) > 0:
            recognitions = non_total[non_total['adjustment_type'] == 'RECOGNITION']
            assert len(recognitions) > 0, "Missing RECOGNITION entries for late orders"


class TestBalancedAdjustments:
    """Test that adjustments are balanced (sum to zero)."""

    def test_reversals_and_recognitions_balance(self, output_df):
        """
        Total REVERSAL amount should equal total RECOGNITION amount (opposite signs).
        Net adjustment should be approximately zero.
        """
        non_total = output_df[output_df['period_id'] != 'TOTAL']

        reversals = float(non_total[non_total['adjustment_type'] == 'REVERSAL']['adjusted_amount_usd'].sum())
        recognitions = float(non_total[non_total['adjustment_type'] == 'RECOGNITION']['adjusted_amount_usd'].sum())

        # Reversals should be negative, recognitions should be positive
        if len(non_total) > 0:
            assert reversals < 0 or reversals == 0, "REVERSAL amounts should be negative"
            assert recognitions > 0 or recognitions == 0, "RECOGNITION amounts should be positive"

        # Net should be approximately zero (within rounding tolerance)
        net_adjustment = reversals + recognitions
        assert abs(net_adjustment) < 1.0, \
            f"Adjustments not balanced: REVERSAL={reversals:.2f}, RECOGNITION={recognitions:.2f}, net={net_adjustment:.2f}"

    def test_total_row_shows_net_zero(self, output_df):
        """TOTAL row should show net adjustment close to zero."""
        total_row = output_df[output_df['period_id'] == 'TOTAL']
        if len(total_row) > 0:
            net_amount = float(total_row['adjusted_amount_usd'].iloc[0])
            assert abs(net_amount) < 1.0, \
                f"TOTAL row net adjustment should be ~0, got {net_amount:.2f}"


class TestNumericValues:
    """Test that numeric values are reasonable."""

    def test_order_count_positive(self, output_df):
        """Order count should be non-negative."""
        assert (output_df['order_count'] >= 0).all(), "Found negative order counts"

    def test_reversal_amounts_negative(self, output_df):
        """REVERSAL entries should have negative adjusted_amount_usd."""
        reversals = output_df[output_df['adjustment_type'] == 'REVERSAL']
        if len(reversals) > 0:
            assert (reversals['adjusted_amount_usd'] <= 0).all(), \
                "REVERSAL entries should have negative adjusted_amount_usd"

    def test_recognition_amounts_positive(self, output_df):
        """RECOGNITION entries should have positive adjusted_amount_usd."""
        recognitions = output_df[output_df['adjustment_type'] == 'RECOGNITION']
        if len(recognitions) > 0:
            assert (recognitions['adjusted_amount_usd'] >= 0).all(), \
                "RECOGNITION entries should have positive adjusted_amount_usd"

    def test_original_amount_non_negative(self, output_df):
        """Original local amounts should be non-negative."""
        assert (output_df['original_amount_local'] >= 0).all(), \
            "Found negative original_amount_local values"


class TestPeriodFormat:
    """Test that period information is correctly formatted."""

    def test_period_name_format(self, output_df):
        """Period names should be in YYYY-MM format or TOTAL."""
        pattern = r'^(\d{4}-\d{2}|TOTAL)$'
        invalid_rows = ~output_df['period_name'].str.match(pattern, na=False)
        assert not invalid_rows.any(), \
            f"Invalid period_name format: {output_df.loc[invalid_rows, 'period_name'].tolist()}"

    def test_period_id_not_null(self, output_df):
        """Period IDs should not be null."""
        assert output_df['period_id'].notna().all(), "Found null period_id values"


class TestDataConsistency:
    """Test data consistency with source data."""

    def test_late_orders_exist(self, db_conn):
        """Verify that late-arriving orders exist in the source data."""
        conn, db_type = db_conn
        count = execute_scalar(conn, db_type, """
            SELECT COUNT(*) as cnt
            FROM ORDERS.ORDERS
            WHERE STATUS IN ('COMPLETED', 'DELIVERED', 'SHIPPED')
            AND ORDERED_AT < CREATED_AT
            AND DATEDIFF('day', ORDERED_AT, CREATED_AT) > 0
        """)
        # Should have at least some late orders
        assert int(count) > 0, "No late-arriving orders found in source data"

    def test_adjustment_count_reasonable(self, output_df, db_conn):
        """Number of adjustments should be reasonable given source data."""
        conn, db_type = db_conn
        # Count late orders in source
        source_late_orders = int(execute_scalar(conn, db_type, """
            SELECT COUNT(*) as cnt
            FROM ORDERS.ORDERS
            WHERE STATUS IN ('COMPLETED', 'DELIVERED', 'SHIPPED')
            AND ORDERED_AT < CREATED_AT
            AND DATEDIFF('day', ORDERED_AT, CREATED_AT) > 0
        """))

        # Total orders in output (from TOTAL row)
        total_row = output_df[output_df['period_id'] == 'TOTAL']
        if len(total_row) > 0:
            output_orders = int(total_row['order_count'].iloc[0])
            # Output should have <= source late orders
            # (some may be in same period and not need adjustment)
            assert output_orders <= source_late_orders, \
                f"More adjustments ({output_orders}) than late orders ({source_late_orders})"


class TestVarianceReason:
    """Test variance reason descriptions."""

    def test_variance_reason_not_empty(self, output_df):
        """Variance reason should not be empty."""
        assert output_df['variance_reason'].notna().all(), "Found null variance_reason"
        assert (output_df['variance_reason'].str.len() > 0).all(), "Found empty variance_reason"


class TestSorting:
    """Test that output is sorted correctly."""

    def test_sorted_by_period_name_then_adjustment_type(self, output_df):
        """Output should be sorted by period_name, then adjustment_type."""
        # Exclude TOTAL row for sorting check
        non_total = output_df[output_df['period_id'] != 'TOTAL'].copy()
        if len(non_total) > 1:
            # Check if sorted by period_name first, then adjustment_type
            sorted_df = non_total.sort_values(['period_name', 'adjustment_type'])
            pd.testing.assert_frame_equal(
                non_total.reset_index(drop=True),
                sorted_df.reset_index(drop=True),
                check_names=False
            )
