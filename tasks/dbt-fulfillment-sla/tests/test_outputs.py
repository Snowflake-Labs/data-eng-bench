"""
Test suite for dbt-fulfillment-sla task.

Tests are organized in phases to ensure systematic validation:
1. Structure - Models exist with correct columns
2. Valid Values - Categorical fields have expected values
3. Positive Values - Numeric fields are positive where expected
4. Calculations - Mathematical relationships hold
5. Percentage Ranges - Percentages are 0-100
6. Classification Logic - Tiers and ratings assigned correctly
7. Ranking - Rankings are valid and ordered
8. Time Metrics - Date/time calculations are sensible
9. Summary Consistency - Aggregations match
10. Materialization - Correct table/view types
11. Idempotency - Re-running produces same results
"""

import subprocess
import os
import pytest
from decimal import Decimal


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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# =============================================================================
# Fixtures
# =============================================================================

def run_dbt():
    """Run dbt to create the models."""
    result = subprocess.run(
        ['dbt', 'run', '--select', 'int_shipment_times', 'fulfillment_sla', 'carrier_performance', 'warehouse_performance', 'fulfillment_summary'],
        cwd=get_dbt_project_dir(),
        capture_output=True,
        text=True
    )
    print(f"CMD: dbt run --select int_shipment_times fulfillment_sla carrier_performance warehouse_performance fulfillment_summary")
    print(f"STDOUT: {result.stdout}")
    if result.returncode != 0:
        print(f"STDERR: {result.stderr}")
    return result.returncode == 0


def query_model(table_name):
    """Query a model from the database."""
    conn, db_type = get_db_connection()
    try:
        try:
            return execute_query(conn, db_type, f"SELECT * FROM main.{table_name}")
        except:
            return execute_query(conn, db_type, f"SELECT * FROM {table_name}")
    finally:
        conn.close()


def query_model_columns(table_name):
    """Get column names for a model."""
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            rows = execute_query(conn, db_type,
                f"SELECT column_name FROM information_schema.columns WHERE lower(table_name) = lower('{table_name}') AND lower(table_schema) = lower('{'main'}') ORDER BY ordinal_position")
            return [r[0].lower() for r in rows]
        else:
            try:
                result = execute_query(conn, db_type, f"DESCRIBE {('main')}.{table_name}")
            except:
                result = execute_query(conn, db_type, f"DESCRIBE {table_name}")
            return [r[0] for r in result]
    finally:
        conn.close()


def get_column_map(table_name):
    """Get mapping of column names to indices for a table."""
    cols = query_model_columns(table_name)
    return {name: idx for idx, name in enumerate(cols)}


def get_table_type(table_name):
    """Get the type of a table (BASE TABLE or VIEW)."""
    conn, db_type = get_db_connection()
    try:
        result = execute_scalar(conn, db_type, f"""
            SELECT table_type
            FROM information_schema.tables
            WHERE lower(table_name) = lower('{table_name}')
            AND lower(table_schema) = 'main'
        """)
        return result
    finally:
        conn.close()


@pytest.fixture(scope="session")
def dbt_run():
    """Run dbt once for all tests."""
    success = run_dbt()
    assert success, "dbt run failed"
    return success


@pytest.fixture(scope="session")
def sla_rows(dbt_run):
    """Get fulfillment_sla rows."""
    return query_model('fulfillment_sla')


@pytest.fixture(scope="session")
def sla_cols(dbt_run):
    """Get column map for fulfillment_sla."""
    return get_column_map('fulfillment_sla')


@pytest.fixture(scope="session")
def carrier_rows(dbt_run):
    """Get carrier_performance rows."""
    return query_model('carrier_performance')


@pytest.fixture(scope="session")
def carrier_cols(dbt_run):
    """Get column map for carrier_performance."""
    return get_column_map('carrier_performance')


@pytest.fixture(scope="session")
def warehouse_rows(dbt_run):
    """Get warehouse_performance rows."""
    return query_model('warehouse_performance')


@pytest.fixture(scope="session")
def warehouse_cols(dbt_run):
    """Get column map for warehouse_performance."""
    return get_column_map('warehouse_performance')


@pytest.fixture(scope="session")
def summary_rows(dbt_run):
    """Get fulfillment_summary rows."""
    return query_model('fulfillment_summary')


@pytest.fixture(scope="session")
def summary_cols(dbt_run):
    """Get column map for fulfillment_summary."""
    return get_column_map('fulfillment_summary')


# =============================================================================
# Phase 1: Structure Tests
# =============================================================================

class TestPhase1Structure:
    """Test that models exist with correct structure."""

    def test_sla_exists(self, sla_rows):
        """fulfillment_sla model exists and has data."""
        print("\n" + "="*50)
        print("PHASE 1: Structure")
        print("="*50)
        assert len(sla_rows) > 0, "fulfillment_sla should have rows"

    def test_sla_columns(self, dbt_run):
        """fulfillment_sla has expected column count."""
        cols = query_model_columns('fulfillment_sla')
        assert len(cols) == 44, f"Expected 44 columns, got {len(cols)}: {cols}"

    def test_carrier_exists(self, carrier_rows):
        """carrier_performance model exists and has data."""
        assert len(carrier_rows) > 0, "carrier_performance should have rows"

    def test_carrier_columns(self, dbt_run):
        """carrier_performance has expected column count."""
        cols = query_model_columns('carrier_performance')
        assert len(cols) == 40, f"Expected 40 columns, got {len(cols)}: {cols}"

    def test_warehouse_exists(self, warehouse_rows):
        """warehouse_performance model exists and has data."""
        assert len(warehouse_rows) > 0, "warehouse_performance should have rows"

    def test_warehouse_columns(self, dbt_run):
        """warehouse_performance has expected column count."""
        cols = query_model_columns('warehouse_performance')
        assert len(cols) == 42, f"Expected 42 columns, got {len(cols)}: {cols}"

    def test_summary_exists(self, summary_rows):
        """fulfillment_summary model exists and has data."""
        assert len(summary_rows) > 0, "fulfillment_summary should have rows"

    def test_summary_columns(self, dbt_run):
        """fulfillment_summary has expected column count."""
        cols = query_model_columns('fulfillment_summary')
        assert len(cols) == 12, f"Expected 12 columns, got {len(cols)}: {cols}"


# =============================================================================
# Phase 2: Valid Values Tests
# =============================================================================

class TestPhase2ValidValues:
    """Test that categorical fields have valid values."""

    def test_valid_service_tiers(self, summary_rows, summary_cols):
        """Service tier values are Express or Standard."""
        print("\n" + "="*50)
        print("PHASE 2: Valid Values")
        print("="*50)
        for r in summary_rows:
            tier = r[summary_cols['service_tier']]
            assert tier in ('Express', 'Standard'), f"Invalid service tier: {tier}"

    def test_valid_performance_tiers(self, carrier_rows, carrier_cols):
        """Performance tier values are valid."""
        valid_tiers = {'Elite', 'Strong', 'Average', 'Underperforming'}
        for r in carrier_rows:
            tier = r[carrier_cols['performance_tier']]
            assert tier in valid_tiers, f"Invalid performance tier: {tier}"

    def test_valid_recent_trends(self, carrier_rows, carrier_cols):
        """Recent trend values are valid or NULL."""
        valid_trends = {'Improving', 'Stable', 'Declining', None}
        for r in carrier_rows:
            trend = r[carrier_cols['recent_trend']]
            assert trend in valid_trends, f"Invalid recent trend: {trend}"

    def test_valid_warehouse_performance_tiers(self, warehouse_rows, warehouse_cols):
        """Warehouse performance tier values are valid."""
        valid_tiers = {'Elite', 'Strong', 'Average', 'Underperforming'}
        for r in warehouse_rows:
            tier = r[warehouse_cols['performance_tier']]
            assert tier in valid_tiers, f"Invalid warehouse performance tier: {tier}"

    def test_valid_month_format(self, sla_rows, sla_cols):
        """Month format is YYYY-MM."""
        import re
        pattern = re.compile(r'^\d{4}-\d{2}$')
        for r in sla_rows:
            month = r[sla_cols['fulfillment_month']]
            assert pattern.match(month), f"Invalid month format: {month}"

    def test_valid_month_range(self, sla_rows, sla_cols):
        """Months are within analysis period (2023-01 to 2024-11)."""
        for r in sla_rows:
            month = r[sla_cols['fulfillment_month']]
            assert '2023-01' <= month <= '2024-11', f"Month {month} outside analysis period 2023-01 to 2024-11"

    def test_is_peak_month_logic(self, sla_rows, sla_cols):
        """is_peak_month is true/1 only for November and December."""
        for r in sla_rows:
            month = r[sla_cols['fulfillment_month']]
            is_peak = r[sla_cols['is_peak_month']]
            month_num = month[-2:]  # Get MM part
            expected_peak = month_num in ('11', '12')
            # Handle both boolean and integer representations
            if isinstance(is_peak, bool):
                actual_peak = is_peak
            else:
                actual_peak = int(is_peak) == 1 if is_peak is not None else False
            assert actual_peak == expected_peak, f"is_peak_month wrong for {month}: got {is_peak}, expected {expected_peak}"

    def test_value_tier_distribution_format(self, summary_rows, summary_cols):
        """value_tier_distribution follows format 'Budget: X.X%, Standard: Y.Y%, Premium: Z.Z%' with 1 decimal."""
        import re
        # Require exactly 1 decimal place (e.g., "25.5%" not "25%" or "25.55%")
        pattern = re.compile(r'^Budget: \d+\.\d%, Standard: \d+\.\d%, Premium: \d+\.\d%$')
        for r in summary_rows:
            dist = r[summary_cols['value_tier_distribution']]
            assert pattern.match(dist), f"Invalid value_tier_distribution format: {dist}. Expected format: 'Budget: X.X%, Standard: Y.Y%, Premium: Z.Z%'"


# =============================================================================
# Phase 3: Positive Values Tests
# =============================================================================

class TestPhase3PositiveValues:
    """Test that numeric fields are positive where expected."""

    def test_positive_shipments(self, sla_rows, sla_cols):
        """Total shipments is positive."""
        print("\n" + "="*50)
        print("PHASE 3: Positive Values")
        print("="*50)
        for r in sla_rows:
            total = int(r[sla_cols['total_shipments']])
            assert total > 0, f"Total shipments should be positive: {total}"

    def test_positive_order_value(self, sla_rows, sla_cols):
        """Total order value is positive."""
        for r in sla_rows:
            value = float(r[sla_cols['total_order_value']])
            assert value > 0, f"Total order value should be positive: {value}"

    def test_positive_time_metrics(self, sla_rows, sla_cols):
        """Time metrics are non-negative."""
        for r in sla_rows:
            avg_processing = float(r[sla_cols['avg_processing_days']])
            avg_transit = float(r[sla_cols['avg_transit_days']])
            avg_total = float(r[sla_cols['avg_total_days']])
            assert avg_processing >= 0, f"Processing days should be non-negative: {avg_processing}"
            assert avg_transit >= 0, f"Transit days should be non-negative: {avg_transit}"
            assert avg_total >= 0, f"Total days should be non-negative: {avg_total}"

    def test_carrier_positive_shipments(self, carrier_rows, carrier_cols):
        """Carrier shipments are positive."""
        for r in carrier_rows:
            total = int(r[carrier_cols['total_shipments']])
            assert total > 0, f"Carrier shipments should be positive: {total}"

    def test_warehouse_positive_shipments(self, warehouse_rows, warehouse_cols):
        """Warehouse shipments are positive."""
        for r in warehouse_rows:
            total = int(r[warehouse_cols['total_shipments']])
            assert total > 0, f"Warehouse shipments should be positive: {total}"


# =============================================================================
# Phase 4: Calculations Tests
# =============================================================================

class TestPhase4Calculations:
    """Test that calculations are correct."""

    def test_sla_counts_sum(self, sla_rows, sla_cols):
        """Early + ontime + late = total shipments."""
        print("\n" + "="*50)
        print("PHASE 4: Calculations")
        print("="*50)
        for r in sla_rows:
            total = int(r[sla_cols['total_shipments']])
            early = int(r[sla_cols['early_count']])
            ontime = int(r[sla_cols['ontime_count']])
            late = int(r[sla_cols['late_count']])
            assert early + ontime + late == total, f"SLA counts don't sum: {early}+{ontime}+{late} != {total}"

    def test_breach_counts_sum(self, sla_rows, sla_cols):
        """Minor + major + severe = late count."""
        for r in sla_rows:
            late = int(r[sla_cols['late_count']])
            minor = int(r[sla_cols['minor_breach_count']])
            major = int(r[sla_cols['major_breach_count']])
            severe = int(r[sla_cols['severe_breach_count']])
            assert minor + major + severe == late, f"Breach counts don't sum: {minor}+{major}+{severe} != {late}"

    def test_value_tier_counts_sum(self, sla_rows, sla_cols):
        """Budget + standard + premium = total shipments."""
        for r in sla_rows:
            total = int(r[sla_cols['total_shipments']])
            budget = int(r[sla_cols['budget_shipments']])
            standard = int(r[sla_cols['standard_shipments']])
            premium = int(r[sla_cols['premium_shipments']])
            assert budget + standard + premium == total, f"Value tiers don't sum: {budget}+{standard}+{premium} != {total}"

    def test_sla_compliance_rate(self, sla_rows, sla_cols):
        """SLA compliance rate = (early + ontime) / total * 100."""
        for r in sla_rows:
            total = int(r[sla_cols['total_shipments']])
            early = int(r[sla_cols['early_count']])
            ontime = int(r[sla_cols['ontime_count']])
            rate = float(r[sla_cols['sla_compliance_rate']])
            expected = round(100.0 * (early + ontime) / total, 1)
            assert abs(rate - expected) < 0.2, f"SLA rate mismatch: {rate} vs {expected}"

    def test_carrier_composite_score(self, carrier_rows, carrier_cols):
        """Composite score = speed*0.3 + reliability*0.5 + consistency*0.2."""
        for r in carrier_rows:
            speed = float(r[carrier_cols['speed_score']])
            reliability = float(r[carrier_cols['reliability_score']])
            consistency = float(r[carrier_cols['consistency_score']])
            composite = float(r[carrier_cols['composite_score']])
            expected = round(speed * 0.3 + reliability * 0.5 + consistency * 0.2, 1)
            assert abs(composite - expected) < 0.2, f"Composite score mismatch: {composite} vs {expected}"

    def test_warehouse_composite_score(self, warehouse_rows, warehouse_cols):
        """Warehouse composite score = efficiency*0.4 + reliability*0.4 + consistency*0.2."""
        import math
        for r in warehouse_rows:
            efficiency = float(r[warehouse_cols['efficiency_score']])
            reliability = float(r[warehouse_cols['reliability_score']])
            consistency = float(r[warehouse_cols['consistency_score']])
            composite = float(r[warehouse_cols['composite_score']])
            expected = round(efficiency * 0.4 + reliability * 0.4 + consistency * 0.2, 1)
            assert abs(composite - expected) < 0.2, f"Warehouse composite score mismatch: {composite} vs {expected}"

    def test_carrier_volume_weighted_score(self, carrier_rows, carrier_cols):
        """Volume weighted score = composite * (1 + ln(total_shipments) / 10)."""
        import math
        for r in carrier_rows:
            total_shipments = int(r[carrier_cols['total_shipments']])
            composite = float(r[carrier_cols['composite_score']])
            volume_weighted = float(r[carrier_cols['volume_weighted_score']])
            expected = round(composite * (1 + math.log(total_shipments) / 10), 1)
            assert abs(volume_weighted - expected) < 0.2, f"Volume weighted score mismatch: {volume_weighted} vs {expected}"

    def test_warehouse_volume_weighted_score(self, warehouse_rows, warehouse_cols):
        """Warehouse volume weighted score = composite * (1 + ln(total_shipments) / 10)."""
        import math
        for r in warehouse_rows:
            total_shipments = int(r[warehouse_cols['total_shipments']])
            composite = float(r[warehouse_cols['composite_score']])
            volume_weighted = float(r[warehouse_cols['volume_weighted_score']])
            expected = round(composite * (1 + math.log(total_shipments) / 10), 1)
            assert abs(volume_weighted - expected) < 0.2, f"Warehouse volume weighted score mismatch: {volume_weighted} vs {expected}"


# =============================================================================
# Phase 5: Percentage Ranges Tests
# =============================================================================

class TestPhase5PercentageRanges:
    """Test that percentages are in valid ranges."""

    def test_sla_percentages_range(self, sla_rows, sla_cols):
        """SLA percentages are 0-100."""
        print("\n" + "="*50)
        print("PHASE 5: Percentage Ranges")
        print("="*50)
        for r in sla_rows:
            early_pct = float(r[sla_cols['early_pct']])
            ontime_pct = float(r[sla_cols['ontime_pct']])
            late_pct = float(r[sla_cols['late_pct']])
            assert 0 <= early_pct <= 100, f"Invalid early_pct: {early_pct}"
            assert 0 <= ontime_pct <= 100, f"Invalid ontime_pct: {ontime_pct}"
            assert 0 <= late_pct <= 100, f"Invalid late_pct: {late_pct}"

    def test_sla_percentages_sum(self, sla_rows, sla_cols):
        """Early + ontime + late percentages sum to ~100."""
        for r in sla_rows:
            early_pct = float(r[sla_cols['early_pct']])
            ontime_pct = float(r[sla_cols['ontime_pct']])
            late_pct = float(r[sla_cols['late_pct']])
            total_pct = early_pct + ontime_pct + late_pct
            assert abs(total_pct - 100) < 1, f"Percentages don't sum to 100: {total_pct}"

    def test_carrier_scores_range(self, carrier_rows, carrier_cols):
        """Carrier scores are 0-100."""
        for r in carrier_rows:
            speed = float(r[carrier_cols['speed_score']])
            reliability = float(r[carrier_cols['reliability_score']])
            consistency = float(r[carrier_cols['consistency_score']])
            composite = float(r[carrier_cols['composite_score']])
            assert 0 <= speed <= 100, f"Invalid speed score: {speed}"
            assert 0 <= reliability <= 100, f"Invalid reliability score: {reliability}"
            assert 0 <= consistency <= 100, f"Invalid consistency score: {consistency}"
            assert 0 <= composite <= 100, f"Invalid composite score: {composite}"

    def test_warehouse_scores_range(self, warehouse_rows, warehouse_cols):
        """Warehouse scores are 0-100."""
        for r in warehouse_rows:
            efficiency = float(r[warehouse_cols['efficiency_score']])
            reliability = float(r[warehouse_cols['reliability_score']])
            consistency = float(r[warehouse_cols['consistency_score']])
            composite = float(r[warehouse_cols['composite_score']])
            assert 0 <= efficiency <= 100, f"Invalid efficiency score: {efficiency}"
            assert 0 <= reliability <= 100, f"Invalid reliability score: {reliability}"
            assert 0 <= consistency <= 100, f"Invalid consistency score: {consistency}"
            assert 0 <= composite <= 100, f"Invalid composite score: {composite}"

    def test_summary_percentages_range(self, summary_rows, summary_cols):
        """Summary percentages are 0-100."""
        for r in summary_rows:
            sla_rate = float(r[summary_cols['sla_compliance_rate']])
            severe_pct = float(r[summary_cols['severe_breach_pct']])
            warehouse_pct = float(r[summary_cols['warehouse_delay_pct']])
            carrier_pct = float(r[summary_cols['carrier_delay_pct']])
            carrier_vol = float(r[summary_cols['pct_of_carrier_volume']])
            total_vol = float(r[summary_cols['pct_of_total_volume']])
            assert 0 <= sla_rate <= 100, f"Invalid SLA rate: {sla_rate}"
            assert 0 <= severe_pct <= 100, f"Invalid severe_breach_pct: {severe_pct}"
            assert 0 <= warehouse_pct <= 100, f"Invalid warehouse_delay_pct: {warehouse_pct}"
            assert 0 <= carrier_pct <= 100, f"Invalid carrier_delay_pct: {carrier_pct}"
            assert 0 <= carrier_vol <= 100, f"Invalid pct_of_carrier_volume: {carrier_vol}"
            assert 0 <= total_vol <= 100, f"Invalid pct_of_total_volume: {total_vol}"


# =============================================================================
# Phase 6: Classification Logic Tests
# =============================================================================

class TestPhase6ClassificationLogic:
    """Test that classifications are assigned correctly."""

    def test_performance_tier_elite(self, carrier_rows, carrier_cols):
        """Elite tier requires composite_score >= 85."""
        print("\n" + "="*50)
        print("PHASE 6: Classification Logic")
        print("="*50)
        for r in carrier_rows:
            tier = r[carrier_cols['performance_tier']]
            composite = float(r[carrier_cols['composite_score']])
            if tier == 'Elite':
                assert composite >= 85, f"Elite should have score >= 85: {composite}"

    def test_performance_tier_underperforming(self, carrier_rows, carrier_cols):
        """Underperforming tier has composite_score < 55."""
        for r in carrier_rows:
            tier = r[carrier_cols['performance_tier']]
            composite = float(r[carrier_cols['composite_score']])
            if tier == 'Underperforming':
                assert composite < 55, f"Underperforming should have score < 55: {composite}"

    def test_performance_tier_boundaries(self, carrier_rows, carrier_cols):
        """Performance tier boundaries are correct."""
        for r in carrier_rows:
            tier = r[carrier_cols['performance_tier']]
            score = float(r[carrier_cols['composite_score']])
            if score >= 85:
                assert tier == 'Elite', f"Score {score} should be Elite, got {tier}"
            elif score >= 70:
                assert tier == 'Strong', f"Score {score} should be Strong, got {tier}"
            elif score >= 55:
                assert tier == 'Average', f"Score {score} should be Average, got {tier}"
            else:
                assert tier == 'Underperforming', f"Score {score} should be Underperforming, got {tier}"

    def test_warehouse_performance_tier_boundaries(self, warehouse_rows, warehouse_cols):
        """Warehouse performance tier boundaries are correct."""
        for r in warehouse_rows:
            tier = r[warehouse_cols['performance_tier']]
            score = float(r[warehouse_cols['composite_score']])
            if score >= 85:
                assert tier == 'Elite', f"Score {score} should be Elite, got {tier}"
            elif score >= 70:
                assert tier == 'Strong', f"Score {score} should be Strong, got {tier}"
            elif score >= 55:
                assert tier == 'Average', f"Score {score} should be Average, got {tier}"
            else:
                assert tier == 'Underperforming', f"Score {score} should be Underperforming, got {tier}"


# =============================================================================
# Phase 7: Ranking Tests
# =============================================================================

class TestPhase7Ranking:
    """Test that rankings are valid."""

    def test_rank_starts_at_1(self, carrier_rows, carrier_cols):
        """Carrier rank starts at 1."""
        print("\n" + "="*50)
        print("PHASE 7: Ranking")
        print("="*50)
        ranks = [int(r[carrier_cols['carrier_rank']]) for r in carrier_rows]
        assert min(ranks) == 1, f"Rank should start at 1, got {min(ranks)}"

    def test_rank_continuous(self, carrier_rows, carrier_cols):
        """Carrier ranks are continuous (no gaps, but ties allowed)."""
        ranks = sorted([int(r[carrier_cols['carrier_rank']]) for r in carrier_rows])
        # Check no gaps larger than 1
        for i in range(1, len(ranks)):
            assert ranks[i] - ranks[i-1] <= 1 or ranks[i] == ranks[i-1], f"Rank gap detected: {ranks[i-1]} to {ranks[i]}"

    def test_ordered_by_composite_score(self, carrier_rows, carrier_cols):
        """Carriers are ordered by composite score descending."""
        scores = [float(r[carrier_cols['composite_score']]) for r in carrier_rows]
        for i in range(1, len(scores)):
            assert scores[i] <= scores[i-1], f"Not ordered by score: {scores[i-1]} then {scores[i]}"

    def test_rank_within_type_starts_at_1(self, carrier_rows, carrier_cols):
        """Rank within type starts at 1 for each carrier type."""
        type_ranks = {}
        for r in carrier_rows:
            carrier_type = r[carrier_cols['carrier_type']]
            rank_within = int(r[carrier_cols['rank_within_type']])
            if carrier_type not in type_ranks:
                type_ranks[carrier_type] = []
            type_ranks[carrier_type].append(rank_within)

        for ctype, ranks in type_ranks.items():
            assert min(ranks) == 1, f"Rank within type {ctype} should start at 1, got {min(ranks)}"

    def test_warehouse_rank_starts_at_1(self, warehouse_rows, warehouse_cols):
        """Warehouse rank starts at 1."""
        ranks = [int(r[warehouse_cols['warehouse_rank']]) for r in warehouse_rows]
        assert min(ranks) == 1, f"Warehouse rank should start at 1, got {min(ranks)}"

    def test_warehouse_rank_within_type_starts_at_1(self, warehouse_rows, warehouse_cols):
        """Warehouse rank within type starts at 1 for each warehouse type."""
        type_ranks = {}
        for r in warehouse_rows:
            warehouse_type = r[warehouse_cols['warehouse_type']]
            rank_within = int(r[warehouse_cols['rank_within_type']])
            if warehouse_type not in type_ranks:
                type_ranks[warehouse_type] = []
            type_ranks[warehouse_type].append(rank_within)

        for wtype, ranks in type_ranks.items():
            assert min(ranks) == 1, f"Rank within warehouse type {wtype} should start at 1, got {min(ranks)}"


# =============================================================================
# Phase 8: Time Metrics Tests
# =============================================================================

class TestPhase8TimeMetrics:
    """Test time-related metrics."""

    def test_percentile_ordering(self, sla_rows, sla_cols):
        """Percentiles are in correct order: p50 <= p75 <= p90 <= p95."""
        print("\n" + "="*50)
        print("PHASE 8: Time Metrics")
        print("="*50)
        for r in sla_rows:
            p50 = float(r[sla_cols['p50_total_days']])
            p75 = float(r[sla_cols['p75_total_days']])
            p90 = float(r[sla_cols['p90_total_days']])
            p95 = float(r[sla_cols['p95_total_days']])
            assert p50 <= p75, f"p50 > p75: {p50} > {p75}"
            assert p75 <= p90, f"p75 > p90: {p75} > {p90}"
            assert p90 <= p95, f"p90 > p95: {p90} > {p95}"

    def test_min_max_bounds(self, sla_rows, sla_cols):
        """Min <= p50 and p95 <= max."""
        for r in sla_rows:
            min_days = int(r[sla_cols['min_total_days']])
            max_days = int(r[sla_cols['max_total_days']])
            p50 = float(r[sla_cols['p50_total_days']])
            p95 = float(r[sla_cols['p95_total_days']])
            assert min_days <= p50, f"min > p50: {min_days} > {p50}"
            assert p95 <= max_days, f"p95 > max: {p95} > {max_days}"

    def test_carrier_date_order(self, carrier_rows, carrier_cols):
        """First shipment date <= last shipment date."""
        for r in carrier_rows:
            first_date = r[carrier_cols['first_shipment_date']]
            last_date = r[carrier_cols['last_shipment_date']]
            assert first_date <= last_date, f"First date after last: {first_date} > {last_date}"

    def test_active_months_positive(self, carrier_rows, carrier_cols):
        """Active months is positive."""
        for r in carrier_rows:
            months = int(r[carrier_cols['active_months']])
            assert months > 0, f"Active months should be positive: {months}"

    def test_warehouse_date_order(self, warehouse_rows, warehouse_cols):
        """Warehouse first shipment date <= last shipment date."""
        for r in warehouse_rows:
            first_date = r[warehouse_cols['first_shipment_date']]
            last_date = r[warehouse_cols['last_shipment_date']]
            assert first_date <= last_date, f"First date after last: {first_date} > {last_date}"

    def test_warehouse_active_months_positive(self, warehouse_rows, warehouse_cols):
        """Warehouse active months is positive."""
        for r in warehouse_rows:
            months = int(r[warehouse_cols['active_months']])
            assert months > 0, f"Active months should be positive: {months}"


# =============================================================================
# Phase 9: Summary Consistency Tests
# =============================================================================

class TestPhase9SummaryConsistency:
    """Test that summary aggregations are consistent."""

    def test_summary_totals_match_carrier(self, carrier_rows, carrier_cols, summary_rows, summary_cols):
        """Summary totals per carrier match carrier_performance totals."""
        print("\n" + "="*50)
        print("PHASE 9: Summary Consistency")
        print("="*50)
        # Sum shipments by carrier from summary
        summary_by_carrier = {}
        for r in summary_rows:
            carrier = r[summary_cols['carrier_name']]
            shipments = int(r[summary_cols['total_shipments']])
            summary_by_carrier[carrier] = summary_by_carrier.get(carrier, 0) + shipments

        # Compare with carrier_performance
        for r in carrier_rows:
            carrier = r[carrier_cols['carrier_name']]
            total = int(r[carrier_cols['total_shipments']])
            if carrier in summary_by_carrier:
                assert summary_by_carrier[carrier] == total, f"Carrier {carrier} mismatch: {summary_by_carrier[carrier]} vs {total}"

    def test_pct_of_total_sums_to_100(self, summary_rows, summary_cols):
        """pct_of_total_volume sums to approximately 100."""
        total_pct = sum(float(r[summary_cols['pct_of_total_volume']]) for r in summary_rows)
        assert abs(total_pct - 100) < 1, f"pct_of_total should sum to 100: {total_pct}"

    def test_pct_of_carrier_sums_to_100(self, summary_rows, summary_cols):
        """pct_of_carrier_volume sums to 100 per carrier."""
        carrier_pcts = {}
        for r in summary_rows:
            carrier = r[summary_cols['carrier_name']]
            pct = float(r[summary_cols['pct_of_carrier_volume']])
            carrier_pcts[carrier] = carrier_pcts.get(carrier, 0) + pct

        for carrier, total in carrier_pcts.items():
            assert abs(total - 100) < 1, f"Carrier {carrier} pct_of_carrier should sum to 100: {total}"


# =============================================================================
# Phase 10: Materialization Tests
# =============================================================================

class TestPhase10Materialization:
    """Test that models have correct materialization."""

    def test_sla_is_table(self, dbt_run):
        """fulfillment_sla is materialized as table."""
        print("\n" + "="*50)
        print("PHASE 10: Materialization")
        print("="*50)
        table_type = get_table_type('fulfillment_sla')
        assert table_type == 'BASE TABLE', f"fulfillment_sla should be TABLE, got {table_type}"

    def test_carrier_is_table(self, dbt_run):
        """carrier_performance is materialized as table."""
        table_type = get_table_type('carrier_performance')
        assert table_type == 'BASE TABLE', f"carrier_performance should be TABLE, got {table_type}"

    def test_warehouse_is_table(self, dbt_run):
        """warehouse_performance is materialized as table."""
        table_type = get_table_type('warehouse_performance')
        assert table_type == 'BASE TABLE', f"warehouse_performance should be TABLE, got {table_type}"

    def test_summary_is_table(self, dbt_run):
        """fulfillment_summary is materialized as table."""
        table_type = get_table_type('fulfillment_summary')
        assert table_type == 'BASE TABLE', f"fulfillment_summary should be TABLE, got {table_type}"

    def test_intermediate_is_view(self, dbt_run):
        """int_shipment_times is materialized as view."""
        table_type = get_table_type('int_shipment_times')
        assert table_type == 'VIEW', f"int_shipment_times should be VIEW, got {table_type}"


# =============================================================================
# Phase 11: Idempotency Tests
# =============================================================================

class TestPhase11Idempotency:
    """Test that re-running produces same results."""

    def test_idempotency(self, sla_rows, carrier_rows, summary_rows):
        """Re-running dbt produces same row counts."""
        print("\n" + "="*50)
        print("PHASE 11: Idempotency")
        print("="*50)
        original_sla_count = len(sla_rows)
        original_carrier_count = len(carrier_rows)
        original_summary_count = len(summary_rows)

        # Re-run dbt
        success = run_dbt()
        assert success, "Second dbt run failed"

        # Check counts match
        new_sla = query_model('fulfillment_sla')
        new_carrier = query_model('carrier_performance')
        new_summary = query_model('fulfillment_summary')

        assert len(new_sla) == original_sla_count, f"SLA count changed: {original_sla_count} to {len(new_sla)}"
        assert len(new_carrier) == original_carrier_count, f"Carrier count changed: {original_carrier_count} to {len(new_carrier)}"
        assert len(new_summary) == original_summary_count, f"Summary count changed: {original_summary_count} to {len(new_summary)}"


# =============================================================================
# Phase 12: Data Quality Tests
# =============================================================================

class TestPhase12DataQuality:
    """Test data quality constraints."""

    def test_no_null_required_fields_sla(self, sla_rows, sla_cols):
        """Required fields in fulfillment_sla are not NULL."""
        print("\n" + "="*50)
        print("PHASE 12: Data Quality")
        print("="*50)
        required_fields = [
            'fulfillment_month', 'shipping_method_id', 'shipping_method_name',
            'warehouse_id', 'warehouse_name', 'carrier_name',
            'total_shipments', 'total_order_value', 'avg_processing_days',
            'avg_transit_days', 'avg_total_days', 'early_count', 'ontime_count',
            'late_count', 'sla_compliance_rate'
        ]
        for r in sla_rows:
            for field in required_fields:
                assert r[sla_cols[field]] is not None, f"NULL found in column {field}"

    def test_no_null_required_fields_carrier(self, carrier_rows, carrier_cols):
        """Required fields in carrier_performance are not NULL."""
        required_fields = [
            'carrier_id', 'carrier_code', 'carrier_name', 'carrier_type',
            'total_shipments', 'total_order_value', 'unique_orders', 'avg_shipment_value',
            'sla_compliance_rate', 'composite_score', 'carrier_rank', 'performance_tier'
        ]
        for r in carrier_rows:
            for field in required_fields:
                assert r[carrier_cols[field]] is not None, f"NULL found in carrier column {field}"

    def test_no_null_required_fields_warehouse(self, warehouse_rows, warehouse_cols):
        """Required fields in warehouse_performance are not NULL."""
        required_fields = [
            'warehouse_id', 'warehouse_code', 'warehouse_name', 'warehouse_type',
            'total_shipments', 'sla_compliance_rate', 'composite_score',
            'warehouse_rank', 'performance_tier'
        ]
        for r in warehouse_rows:
            for field in required_fields:
                assert r[warehouse_cols[field]] is not None, f"NULL found in warehouse column {field}"

    def test_unique_warehouse_ids(self, warehouse_rows, warehouse_cols):
        """Warehouse IDs are unique."""
        warehouse_ids = [r[warehouse_cols['warehouse_id']] for r in warehouse_rows]
        assert len(warehouse_ids) == len(set(warehouse_ids)), "Duplicate warehouse IDs found"

    def test_unique_carrier_ids(self, carrier_rows, carrier_cols):
        """Carrier IDs are unique."""
        carrier_ids = [r[carrier_cols['carrier_id']] for r in carrier_rows]
        assert len(carrier_ids) == len(set(carrier_ids)), "Duplicate carrier IDs found"

    def test_unique_sla_keys(self, sla_rows, sla_cols):
        """Month + shipping_method + warehouse combination is unique."""
        keys = [(r[sla_cols['fulfillment_month']], r[sla_cols['shipping_method_id']], r[sla_cols['warehouse_id']]) for r in sla_rows]
        assert len(keys) == len(set(keys)), "Duplicate SLA keys found"


# =============================================================================
# Phase 13: Value Tier Analysis Tests
# =============================================================================

class TestPhase13ValueTierAnalysis:
    """Test value tier specific logic."""

    def test_tier_sla_rates_nullable(self, sla_rows, sla_cols):
        """Value tier SLA rates are NULL when count is 0."""
        print("\n" + "="*50)
        print("PHASE 13: Value Tier Analysis")
        print("="*50)
        for r in sla_rows:
            budget_count = int(r[sla_cols['budget_shipments']])
            standard_count = int(r[sla_cols['standard_shipments']])
            premium_count = int(r[sla_cols['premium_shipments']])
            budget_rate = r[sla_cols['budget_sla_rate']]
            standard_rate = r[sla_cols['standard_sla_rate']]
            premium_rate = r[sla_cols['premium_sla_rate']]

            if budget_count == 0:
                assert budget_rate is None, f"Budget rate should be NULL when count is 0"
            if standard_count == 0:
                assert standard_rate is None, f"Standard rate should be NULL when count is 0"
            if premium_count == 0:
                assert premium_rate is None, f"Premium rate should be NULL when count is 0"

    def test_carrier_tier_sla_rates_nullable(self, carrier_rows, carrier_cols):
        """Carrier value tier SLA rates are NULL when count is 0."""
        for r in carrier_rows:
            budget_count = int(r[carrier_cols['budget_shipments']])
            standard_count = int(r[carrier_cols['standard_shipments']])
            premium_count = int(r[carrier_cols['premium_shipments']])
            budget_rate = r[carrier_cols['budget_sla_rate']]
            standard_rate = r[carrier_cols['standard_sla_rate']]
            premium_rate = r[carrier_cols['premium_sla_rate']]

            if budget_count == 0:
                assert budget_rate is None, f"Budget rate should be NULL when count is 0"
            if standard_count == 0:
                assert standard_rate is None, f"Standard rate should be NULL when count is 0"
            if premium_count == 0:
                assert premium_rate is None, f"Premium rate should be NULL when count is 0"

    def test_carrier_premium_to_budget_diff_nullable(self, carrier_rows, carrier_cols):
        """premium_to_budget_sla_diff is NULL when either budget or premium SLA rate is NULL."""
        for r in carrier_rows:
            budget_rate = r[carrier_cols['budget_sla_rate']]
            premium_rate = r[carrier_cols['premium_sla_rate']]
            diff = r[carrier_cols['premium_to_budget_sla_diff']]

            if budget_rate is None or premium_rate is None:
                assert diff is None, f"premium_to_budget_sla_diff should be NULL when budget_rate={budget_rate} or premium_rate={premium_rate}"
            else:
                assert diff is not None, f"premium_to_budget_sla_diff should not be NULL when both rates exist"

    def test_warehouse_premium_to_budget_diff_nullable(self, warehouse_rows, warehouse_cols):
        """Warehouse premium_to_budget_sla_diff is NULL when either budget or premium SLA rate is NULL."""
        for r in warehouse_rows:
            budget_rate = r[warehouse_cols['budget_sla_rate']]
            premium_rate = r[warehouse_cols['premium_sla_rate']]
            diff = r[warehouse_cols['premium_to_budget_sla_diff']]

            if budget_rate is None or premium_rate is None:
                assert diff is None, f"premium_to_budget_sla_diff should be NULL when budget_rate={budget_rate} or premium_rate={premium_rate}"
            else:
                assert diff is not None, f"premium_to_budget_sla_diff should not be NULL when both rates exist"


# =============================================================================
# Phase 14: Express vs Standard Tests
# =============================================================================

class TestPhase14ExpressStandard:
    """Test express vs standard shipping logic."""

    def test_express_standard_counts_sum(self, carrier_rows, carrier_cols):
        """Express + standard_shipping = total shipments."""
        print("\n" + "="*50)
        print("PHASE 14: Express vs Standard")
        print("="*50)
        for r in carrier_rows:
            total = int(r[carrier_cols['total_shipments']])
            express = int(r[carrier_cols['express_shipments']])
            standard = int(r[carrier_cols['standard_shipping_shipments']])
            assert express + standard == total, f"Express + Standard != Total: {express} + {standard} != {total}"

    def test_express_sla_rate_nullable(self, carrier_rows, carrier_cols):
        """Express SLA rate is NULL when express_shipments is 0."""
        for r in carrier_rows:
            express_count = int(r[carrier_cols['express_shipments']])
            express_rate = r[carrier_cols['express_sla_rate']]
            if express_count == 0:
                assert express_rate is None, f"Express rate should be NULL when count is 0"

    def test_standard_shipping_sla_rate_nullable(self, carrier_rows, carrier_cols):
        """Standard shipping SLA rate is NULL when standard_shipping_shipments is 0."""
        for r in carrier_rows:
            standard_count = int(r[carrier_cols['standard_shipping_shipments']])
            standard_rate = r[carrier_cols['standard_shipping_sla_rate']]
            if standard_count == 0:
                assert standard_rate is None, f"Standard shipping rate should be NULL when count is 0"

    def test_summary_service_tiers_complete(self, summary_rows, summary_cols):
        """Each carrier should have at most Express and Standard tiers."""
        carrier_tiers = {}
        for r in summary_rows:
            carrier = r[summary_cols['carrier_name']]
            tier = r[summary_cols['service_tier']]
            if carrier not in carrier_tiers:
                carrier_tiers[carrier] = set()
            carrier_tiers[carrier].add(tier)

        for carrier, tiers in carrier_tiers.items():
            for tier in tiers:
                assert tier in ('Express', 'Standard'), f"Invalid tier {tier} for carrier {carrier}"


# =============================================================================
# Phase 15: Delay Attribution Tests
# =============================================================================

class TestPhase15WarehouseCarrierMix:
    """Test warehouse carrier mix fields."""

    def test_primary_carrier_pct_range(self, warehouse_rows, warehouse_cols):
        """Primary carrier percentage is 0-100."""
        print("\n" + "="*50)
        print("PHASE 15: Warehouse Carrier Mix")
        print("="*50)
        for r in warehouse_rows:
            pct = float(r[warehouse_cols['primary_carrier_pct']])
            assert 0 < pct <= 100, f"Invalid primary_carrier_pct: {pct}"

    def test_distinct_carriers_positive(self, warehouse_rows, warehouse_cols):
        """Distinct carriers count is positive."""
        for r in warehouse_rows:
            count = int(r[warehouse_cols['distinct_carriers']])
            assert count > 0, f"Distinct carriers should be positive: {count}"

    def test_primary_carrier_not_null(self, warehouse_rows, warehouse_cols):
        """Primary carrier name is not NULL."""
        for r in warehouse_rows:
            name = r[warehouse_cols['primary_carrier_name']]
            assert name is not None, "Primary carrier name should not be NULL"


class TestPhase16DelayAttribution:
    """Test delay attribution logic."""

    def test_delay_counts_valid(self, sla_rows, sla_cols):
        """Delay counts are valid."""
        print("\n" + "="*50)
        print("PHASE 16: Delay Attribution")
        print("="*50)
        for r in sla_rows:
            total = int(r[sla_cols['total_shipments']])
            warehouse_delay = int(r[sla_cols['warehouse_delay_count']])
            carrier_delay = int(r[sla_cols['carrier_delay_count']])
            both_delay = int(r[sla_cols['both_delay_count']])

            # Both delays should be <= min(warehouse, carrier)
            assert both_delay <= warehouse_delay, f"Both delay > warehouse delay: {both_delay} > {warehouse_delay}"
            assert both_delay <= carrier_delay, f"Both delay > carrier delay: {both_delay} > {carrier_delay}"

            # Delay counts should not exceed total
            assert warehouse_delay <= total, f"Warehouse delay > total: {warehouse_delay} > {total}"
            assert carrier_delay <= total, f"Carrier delay > total: {carrier_delay} > {total}"
