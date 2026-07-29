"""
Test verifier for Incremental Sales Pipeline with Late-Arriving Data.
Multi-phase testing:
  Phase 1: Validate model structure and required columns
  Phase 2: Validate SCD Type 2 order versioning
  Phase 3: Validate channel latency analysis
  Phase 4: Validate revenue reconciliation waterfall
  Phase 5: Validate late arrival metrics and completeness
  Phase 6: Validate data quality scoring
  Phase 7: Validate daily summary
  Phase 8: Test incremental idempotency
"""
import subprocess
import os
from pathlib import Path
import pytest

def _get_project_dir():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return Path(os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake'))
    return Path(os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb'))

PROJECT_DIR = _get_project_dir()
DB_PATH = Path("/app/database/retail.duckdb")
def _get_schema():
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'main_incremental_analytics'

SCHEMA = _get_schema()


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
        db_path = os.environ.get('DUCKDB_PATH', str(DB_PATH))
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


# ============ HELPERS ============


def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = str(PROJECT_DIR)
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline(full_refresh=False):
    """Run dbt pipeline."""
    deps_result = run_cmd("dbt deps")
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")

    cmd = "dbt run --select order_version_history incremental_daily_sales channel_latency_analysis revenue_reconciliation_waterfall late_arrival_metrics order_data_quality daily_sales_summary"
    if full_refresh:
        cmd += " --full-refresh"
    result = run_cmd(cmd)
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def get_source_order_count():
    """Get count of unique non-test orders from source."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, """
            SELECT COUNT(DISTINCT ORDER_ID)
            FROM ORDERS.ORDERS
            WHERE TEST_ORDER_FLAG IS NULL OR COALESCE(CAST(TEST_ORDER_FLAG AS INTEGER), 0) = 0
        """)
        return result
    finally:
        conn.close()


@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline(full_refresh=True)
    return True


class TestPhase1Structure:
    """Phase 1: Validate model structure."""

    def test_models_directory_exists(self, dbt_run):
        """Validate models directory exists."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        models_dir = PROJECT_DIR / "models" / "marts" / "incremental"
        assert models_dir.is_dir(), f"Missing models directory: {models_dir}"

    def test_order_version_history_columns(self, dbt_run):
        """Validate order_version_history has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('order_version_history')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_id", "version_num", "valid_from", "valid_to",
                       "is_current", "grand_total", "status", "customer_id",
                       "channel_id", "ordered_at", "created_at"}
            missing = required - col_names
            assert not missing, f"Missing columns in order_version_history: {missing}"
        finally:
            conn.close()

    def test_incremental_daily_sales_columns(self, dbt_run):
        """Validate incremental_daily_sales has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('incremental_daily_sales')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_id", "order_date", "customer_id", "channel_id",
                       "grand_total", "status", "ordered_at", "created_at",
                       "loaded_at", "arrival_latency_days", "version_count"}
            missing = required - col_names
            assert not missing, f"Missing columns in incremental_daily_sales: {missing}"
        finally:
            conn.close()

    def test_channel_latency_analysis_columns(self, dbt_run):
        """Validate channel_latency_analysis has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('channel_latency_analysis')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"channel_id", "total_orders", "avg_latency_hours",
                       "p50_latency_hours", "p95_latency_hours", "on_time_pct",
                       "late_1_3_pct", "late_3_7_pct", "late_7_plus_pct"}
            missing = required - col_names
            assert not missing, f"Missing columns in channel_latency_analysis: {missing}"
        finally:
            conn.close()

    def test_revenue_reconciliation_waterfall_columns(self, dbt_run):
        """Validate revenue_reconciliation_waterfall has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('revenue_reconciliation_waterfall')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_date", "initial_revenue", "adj_day_1_2",
                       "adj_day_3_7", "adj_day_8_plus", "settled_revenue",
                       "restatement_pct", "order_count"}
            missing = required - col_names
            assert not missing, f"Missing columns in revenue_reconciliation_waterfall: {missing}"
        finally:
            conn.close()

    def test_late_arrival_metrics_columns(self, dbt_run):
        """Validate late_arrival_metrics has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('late_arrival_metrics')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_date", "total_orders", "orders_on_time",
                       "orders_late_1_3", "orders_late_3_7", "orders_late_7_plus",
                       "avg_latency_hours", "p95_latency_hours", "days_since_order",
                       "completeness_pct", "completeness_lower", "completeness_upper"}
            missing = required - col_names
            assert not missing, f"Missing columns in late_arrival_metrics: {missing}"
        finally:
            conn.close()

    def test_order_data_quality_columns(self, dbt_run):
        """Validate order_data_quality has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('order_data_quality')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_id", "order_date", "has_future_order_date",
                       "has_negative_total", "has_null_customer",
                       "has_extreme_latency", "issue_count", "quality_score"}
            missing = required - col_names
            assert not missing, f"Missing columns in order_data_quality: {missing}"
        finally:
            conn.close()

    def test_daily_sales_summary_columns(self, dbt_run):
        """Validate daily_sales_summary has required columns."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE LOWER(table_schema) = LOWER('{SCHEMA}')
                AND LOWER(table_name) = LOWER('daily_sales_summary')
            """)
            col_names = {c[0].lower() for c in cols}
            required = {"order_date", "total_orders", "total_revenue",
                       "unique_customers", "avg_order_value", "completeness_pct",
                       "provisional_flag", "restatement_risk"}
            missing = required - col_names
            assert not missing, f"Missing columns in daily_sales_summary: {missing}"
        finally:
            conn.close()


class TestPhase2SCDType2:
    """Phase 2: Validate SCD Type 2 order versioning."""

    def test_version_num_starts_at_one(self, dbt_run):
        """Validate version_num starts at 1 for each order."""
        print("\n" + "="*50)
        print("PHASE 2: SCD Type 2 Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            result = execute_scalar(conn, db_type, f"""
                SELECT COUNT(DISTINCT order_id)
                FROM {SCHEMA}.order_version_history
                WHERE version_num = 1
            """)
            total_orders = execute_scalar(conn, db_type, f"""
                SELECT COUNT(DISTINCT order_id)
                FROM {SCHEMA}.order_version_history
            """)
            assert result == total_orders, \
                f"Not all orders have version_num=1: {result} vs {total_orders}"
        finally:
            conn.close()

    def test_exactly_one_current_per_order(self, dbt_run):
        """Validate exactly one is_current=true per order_id."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_query(conn, db_type, f"""
                SELECT order_id, COUNT(*) as current_count
                FROM {SCHEMA}.order_version_history
                WHERE CAST(is_current AS INTEGER) = 1
                GROUP BY order_id
                HAVING COUNT(*) != 1
            """)
            assert len(invalid) == 0, \
                f"Orders with != 1 current version: {invalid[:5]}"
        finally:
            conn.close()

    def test_valid_to_null_for_current(self, dbt_run):
        """Validate valid_to is NULL for current version."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.order_version_history
                WHERE CAST(is_current AS INTEGER) = 1 AND valid_to IS NOT NULL
            """)
            assert invalid == 0, \
                f"Found {invalid} current versions with non-NULL valid_to"
        finally:
            conn.close()

    def test_valid_from_equals_created_at(self, dbt_run):
        """Validate valid_from equals created_at."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.order_version_history
                WHERE valid_from != created_at
            """)
            assert invalid == 0, \
                f"Found {invalid} rows where valid_from != created_at"
        finally:
            conn.close()

    def test_version_sequence_continuous(self, dbt_run):
        """Validate version numbers are continuous (1, 2, 3...)."""
        conn, db_type = get_db_connection()
        try:
            # Check that max version_num equals count per order
            invalid = execute_query(conn, db_type, f"""
                SELECT order_id
                FROM {SCHEMA}.order_version_history
                GROUP BY order_id
                HAVING MAX(version_num) != COUNT(*)
            """)
            assert len(invalid) == 0, \
                f"Orders with non-continuous version sequence: {invalid[:5]}"
        finally:
            conn.close()


class TestPhase3ChannelLatency:
    """Phase 3: Validate channel latency analysis."""

    def test_latency_percentages_sum_to_100(self, dbt_run):
        """Validate on_time + late buckets sum to ~100%."""
        print("\n" + "="*50)
        print("PHASE 3: Channel Latency Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT channel_id,
                    on_time_pct + late_1_3_pct + late_3_7_pct + late_7_plus_pct as total_pct
                FROM {SCHEMA}.channel_latency_analysis
            """)
            for channel_id, total_pct in rows:
                assert abs(float(total_pct) - 100.0) < 1.0, \
                    f"Channel {channel_id}: percentages sum to {total_pct}, not ~100"
        finally:
            conn.close()

    def test_p95_greater_than_p50(self, dbt_run):
        """Validate p95 >= p50 latency."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.channel_latency_analysis
                WHERE p95_latency_hours < p50_latency_hours
            """)
            assert invalid == 0, \
                f"Found {invalid} channels where p95 < p50 (impossible)"
        finally:
            conn.close()

    def test_order_counts_match_source(self, dbt_run):
        """Validate total orders across channels matches incremental_daily_sales."""
        conn, db_type = get_db_connection()
        try:
            channel_total = execute_scalar(conn, db_type, f"""
                SELECT SUM(total_orders)
                FROM {SCHEMA}.channel_latency_analysis
            """)
            # Channel analysis excludes orders with negative latency
            orders_with_valid_latency = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.incremental_daily_sales
                WHERE created_at >= ordered_at
            """)
            assert channel_total == orders_with_valid_latency, \
                f"Channel total ({channel_total}) != valid orders ({orders_with_valid_latency})"
        finally:
            conn.close()


class TestPhase4RevenueWaterfall:
    """Phase 4: Validate revenue reconciliation waterfall."""

    def test_settled_revenue_equals_sum_of_buckets(self, dbt_run):
        """Validate settled_revenue = initial + all adjustments."""
        print("\n" + "="*50)
        print("PHASE 4: Revenue Waterfall Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.revenue_reconciliation_waterfall
                WHERE ABS(settled_revenue - (initial_revenue + adj_day_1_2 + adj_day_3_7 + adj_day_8_plus)) > 0.01
            """)
            assert invalid == 0, \
                f"Found {invalid} rows where settled != sum of buckets"
        finally:
            conn.close()

    def test_restatement_pct_calculation(self, dbt_run):
        """Validate restatement_pct = (settled - initial) / initial * 100."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.revenue_reconciliation_waterfall
                WHERE initial_revenue > 0
                AND restatement_pct IS NOT NULL
                AND ABS(restatement_pct - (settled_revenue - initial_revenue) / initial_revenue * 100) > 0.1
            """)
            assert invalid == 0, \
                f"Found {invalid} rows with incorrect restatement_pct"
        finally:
            conn.close()

    def test_order_count_matches_daily_sales(self, dbt_run):
        """Validate order_count matches incremental_daily_sales per date."""
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                SELECT w.order_date, w.order_count, s.sales_count
                FROM {SCHEMA}.revenue_reconciliation_waterfall w
                JOIN (
                    SELECT order_date, COUNT(*) as sales_count
                    FROM {SCHEMA}.incremental_daily_sales
                    GROUP BY order_date
                ) s ON w.order_date = s.order_date
                WHERE w.order_count != s.sales_count
            """)
            assert len(mismatches) == 0, \
                f"Order count mismatches found: {mismatches[:5]}"
        finally:
            conn.close()


class TestPhase5LateArrivalMetrics:
    """Phase 5: Validate late arrival metrics and completeness."""

    def test_latency_buckets_sum_to_total(self, dbt_run):
        """Validate latency bucket counts sum to total_orders."""
        print("\n" + "="*50)
        print("PHASE 5: Late Arrival Metrics Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.late_arrival_metrics
                WHERE (orders_on_time + orders_late_1_3 + orders_late_3_7 + orders_late_7_plus) != total_orders
            """)
            assert invalid == 0, \
                f"Found {invalid} rows where bucket sum != total_orders"
        finally:
            conn.close()

    def test_completeness_range(self, dbt_run):
        """Validate completeness_pct is between 0 and 100."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.late_arrival_metrics
                WHERE completeness_pct < 0 OR completeness_pct > 100
            """)
            assert invalid == 0, \
                f"Found {invalid} rows with completeness_pct outside 0-100"
        finally:
            conn.close()

    def test_confidence_bounds_order(self, dbt_run):
        """Validate completeness_lower <= completeness_pct <= completeness_upper."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.late_arrival_metrics
                WHERE completeness_lower > completeness_pct
                   OR completeness_upper < completeness_pct
            """)
            assert invalid == 0, \
                f"Found {invalid} rows with invalid confidence bounds"
        finally:
            conn.close()

    def test_p95_greater_than_avg_latency(self, dbt_run):
        """Validate p95 >= avg latency."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.late_arrival_metrics
                WHERE p95_latency_hours < avg_latency_hours
                AND total_orders > 5
            """)
            assert invalid == 0, \
                f"Found {invalid} rows where p95 < avg (statistically impossible)"
        finally:
            conn.close()


class TestPhase6DataQuality:
    """Phase 6: Validate data quality scoring."""

    def test_quality_score_range(self, dbt_run):
        """Validate quality_score is between 0 and 100."""
        print("\n" + "="*50)
        print("PHASE 6: Data Quality Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.order_data_quality
                WHERE quality_score < 0 OR quality_score > 100
            """)
            assert invalid == 0, \
                f"Found {invalid} rows with quality_score outside 0-100"
        finally:
            conn.close()

    def test_quality_score_formula(self, dbt_run):
        """Validate quality_score = 100 - (25 * issue_count)."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.order_data_quality
                WHERE quality_score != GREATEST(0, 100 - (25 * issue_count))
            """)
            assert invalid == 0, \
                f"Found {invalid} rows with incorrect quality_score formula"
        finally:
            conn.close()

    def test_issue_count_matches_flags(self, dbt_run):
        """Validate issue_count matches sum of boolean flags."""
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.order_data_quality
                WHERE issue_count != (
                    CASE WHEN has_future_order_date THEN 1 ELSE 0 END +
                    CASE WHEN has_negative_total THEN 1 ELSE 0 END +
                    CASE WHEN has_null_customer THEN 1 ELSE 0 END +
                    CASE WHEN has_extreme_latency THEN 1 ELSE 0 END
                )
            """)
            assert invalid == 0, \
                f"Found {invalid} rows where issue_count != sum of flags"
        finally:
            conn.close()

    def test_all_orders_have_quality_record(self, dbt_run):
        """Validate all orders have quality records."""
        conn, db_type = get_db_connection()
        try:
            missing = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.incremental_daily_sales s
                LEFT JOIN {SCHEMA}.order_data_quality q ON s.order_id = q.order_id
                WHERE q.order_id IS NULL
            """)
            assert missing == 0, \
                f"Found {missing} orders without quality records"
        finally:
            conn.close()


class TestPhase7DailySummary:
    """Phase 7: Validate daily sales summary."""

    def test_provisional_flag_logic(self, dbt_run):
        """Validate provisional_flag is true when completeness < 90%."""
        print("\n" + "="*50)
        print("PHASE 7: Daily Summary Validation")
        print("="*50)
        conn, db_type = get_db_connection()
        try:
            invalid = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.daily_sales_summary
                WHERE (completeness_pct < 90 AND COALESCE(CAST(provisional_flag AS INTEGER), 0) = 0)
                   OR (completeness_pct >= 90 AND CAST(provisional_flag AS INTEGER) = 1)
            """)
            assert invalid == 0, \
                f"Found {invalid} rows with incorrect provisional_flag"
        finally:
            conn.close()

    def test_summary_excludes_low_quality(self, dbt_run):
        """Validate summary only includes orders with quality_score >= 75."""
        conn, db_type = get_db_connection()
        try:
            # Compare summary total to quality-filtered count
            summary_total = execute_scalar(conn, db_type, f"""
                SELECT SUM(total_orders)
                FROM {SCHEMA}.daily_sales_summary
            """)

            quality_filtered_total = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.incremental_daily_sales s
                JOIN {SCHEMA}.order_data_quality q ON s.order_id = q.order_id
                WHERE q.quality_score >= 75
            """)

            assert summary_total == quality_filtered_total, \
                f"Summary total ({summary_total}) != quality filtered ({quality_filtered_total})"
        finally:
            conn.close()

    def test_order_count_matches_source(self, dbt_run):
        """Validate total unique orders matches source."""
        expected_count = get_source_order_count()
        conn, db_type = get_db_connection()
        try:
            actual = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.incremental_daily_sales
            """)
            assert actual == expected_count, \
                f"Order count mismatch: expected {expected_count}, got {actual}"
        finally:
            conn.close()


class TestPhase8Idempotency:
    """Phase 8: Test incremental idempotency."""

    def test_incremental_model_config(self, dbt_run):
        """Validate incremental_daily_sales uses incremental materialization."""
        print("\n" + "="*50)
        print("PHASE 8: Incremental Configuration Validation")
        print("="*50)
        model_file = PROJECT_DIR / "models" / "marts" / "incremental" / "incremental_daily_sales.sql"
        assert model_file.exists(), f"Model file not found: {model_file}"
        content = model_file.read_text().lower()
        assert "materialized='incremental'" in content or 'materialized="incremental"' in content, \
            "Model must use materialized='incremental'"

    def test_unique_key_config(self, dbt_run):
        """Validate unique_key is set."""
        model_file = PROJECT_DIR / "models" / "marts" / "incremental" / "incremental_daily_sales.sql"
        content = model_file.read_text().lower()
        assert "unique_key" in content, \
            "Model must have unique_key configuration"

    def test_adaptive_lookback_uses_latency(self, dbt_run):
        """Validate model uses adaptive lookback based on latency."""
        model_file = PROJECT_DIR / "models" / "marts" / "incremental" / "incremental_daily_sales.sql"
        content = model_file.read_text().lower()
        assert "is_incremental()" in content, \
            "Model must use is_incremental() macro"
        # Check for latency-based lookback
        has_latency_ref = "latency" in content or "p95" in content or "percentile" in content
        assert has_latency_ref, \
            "Model should reference latency statistics for adaptive lookback"

    def test_idempotency_rerun(self, dbt_run):
        """Test that re-running dbt incremental produces same results."""
        conn, db_type = get_db_connection()
        try:
            count_before = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.incremental_daily_sales
            """)
            revenue_before = execute_scalar(conn, db_type, f"""
                SELECT ROUND(SUM(grand_total), 2)
                FROM {SCHEMA}.incremental_daily_sales
            """)
        finally:
            conn.close()

        # Re-run dbt (incremental mode - no full refresh)
        run_dbt_pipeline(full_refresh=False)

        conn, db_type = get_db_connection()
        try:
            count_after = execute_scalar(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {SCHEMA}.incremental_daily_sales
            """)
            revenue_after = execute_scalar(conn, db_type, f"""
                SELECT ROUND(SUM(grand_total), 2)
                FROM {SCHEMA}.incremental_daily_sales
            """)

            assert count_before == count_after, \
                f"Row count changed after incremental run: {count_before} -> {count_after}"
            assert revenue_before == revenue_after, \
                f"Revenue changed after incremental run: {revenue_before} -> {revenue_after}"
            print(f"Idempotency verified: {count_after} rows, {revenue_after} revenue unchanged")
        finally:
            conn.close()
