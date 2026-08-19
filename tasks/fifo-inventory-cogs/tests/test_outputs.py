"""
Test cases for FIFO Inventory COGS calculation.
Strict validation of FIFO ordering and model correctness.
"""

import pytest
import subprocess
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


def _get_schema():
    """Get schema name based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'main_inventory_analytics'


SCHEMA = _get_schema()


# ============ END DUAL-BACKEND INFRASTRUCTURE ============


@pytest.fixture(scope="module")
def db_connection():
    """Create database connection."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# =============================================================================
# Model Existence Tests
# =============================================================================

class TestModelsExist:
    """Test that all 7 required models exist."""

    def test_stg_fifo_transactions_exists(self, db_connection):
        """stg_fifo_transactions model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'stg_fifo_transactions'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.stg_fifo_transactions not found"

    def test_int_receipt_layers_exists(self, db_connection):
        """int_receipt_layers model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'int_receipt_layers'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.int_receipt_layers not found"

    def test_int_pick_consumption_exists(self, db_connection):
        """int_pick_consumption model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'int_pick_consumption'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.int_pick_consumption not found"

    def test_int_fifo_allocation_exists(self, db_connection):
        """int_fifo_allocation model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'int_fifo_allocation'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.int_fifo_allocation not found"

    def test_fifo_cogs_monthly_exists(self, db_connection):
        """fifo_cogs_monthly model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'fifo_cogs_monthly'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.fifo_cogs_monthly not found"

    def test_ending_inventory_valuation_exists(self, db_connection):
        """ending_inventory_valuation model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'ending_inventory_valuation'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.ending_inventory_valuation not found"

    def test_inventory_turnover_analysis_exists(self, db_connection):
        """inventory_turnover_analysis model must exist."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = 'inventory_turnover_analysis'
        """)
        assert int(result) > 0, f"Model {SCHEMA}.inventory_turnover_analysis not found"


# =============================================================================
# Staging Model Tests
# =============================================================================

class TestStagingModel:
    """Test stg_fifo_transactions model."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, f"SELECT * FROM {SCHEMA}.stg_fifo_transactions LIMIT 1")
        # Get column names from cursor description for Snowflake
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.stg_fifo_transactions LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.stg_fifo_transactions LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['transaction_id', 'warehouse_id', 'variant_id', 'transaction_type',
                    'transaction_timestamp', 'transaction_date', 'quantity', 'unit_cost', 'row_num']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_quantity_always_positive(self, db_connection):
        """All quantities must be positive."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.stg_fifo_transactions WHERE quantity <= 0
        """)
        assert int(result) == 0, f"Found {result} rows with non-positive quantity"

    def test_transaction_types(self, db_connection):
        """Only RECEIPT and PICK transaction types."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, f"""
            SELECT DISTINCT transaction_type FROM {SCHEMA}.stg_fifo_transactions
            WHERE transaction_type NOT IN ('RECEIPT', 'PICK')
        """)
        assert len(rows) == 0, f"Unexpected transaction types: {[r[0] for r in rows]}"


# =============================================================================
# Receipt Layers Tests
# =============================================================================

class TestReceiptLayers:
    """Test int_receipt_layers model with strict FIFO validation."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.int_receipt_layers LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.int_receipt_layers LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['receipt_id', 'warehouse_id', 'variant_id', 'receipt_timestamp', 'receipt_date',
                    'receipt_qty', 'unit_cost', 'cumulative_qty_before', 'cumulative_qty_after',
                    'days_since_receipt', 'age_bucket']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_cumulative_qty_before_starts_at_zero(self, db_connection):
        """First receipt per warehouse-variant MUST have cumulative_qty_before = 0."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            WITH first_receipts AS (
                SELECT warehouse_id, variant_id, MIN(cumulative_qty_before) as min_before
                FROM {SCHEMA}.int_receipt_layers
                GROUP BY warehouse_id, variant_id
            )
            SELECT COUNT(*) FROM first_receipts WHERE min_before != 0
        """)
        assert int(result) == 0, f"{result} warehouse-variant combinations don't start at 0"

    def test_cumulative_qty_after_equals_before_plus_qty(self, db_connection):
        """cumulative_qty_after MUST equal cumulative_qty_before + receipt_qty."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_receipt_layers
            WHERE ABS(cumulative_qty_after - cumulative_qty_before - receipt_qty) > 0.001
        """)
        assert int(result) == 0, f"{result} rows violate cumulative calculation"

    def test_strict_fifo_ordering(self, db_connection):
        """Receipts MUST be in strict chronological order with transaction_id tiebreaker."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            WITH ordered AS (
                SELECT
                    warehouse_id, variant_id, receipt_id, receipt_timestamp,
                    cumulative_qty_before,
                    LAG(cumulative_qty_after) OVER (
                        PARTITION BY warehouse_id, variant_id
                        ORDER BY receipt_timestamp, receipt_id
                    ) as prev_after
                FROM {SCHEMA}.int_receipt_layers
            )
            SELECT COUNT(*) FROM ordered
            WHERE prev_after IS NOT NULL
            AND ABS(cumulative_qty_before - prev_after) > 0.001
        """)
        assert int(result) == 0, f"FIFO ordering violated: {result} sequence breaks"

    def test_age_bucket_values(self, db_connection):
        """Age bucket must be one of the valid values."""
        conn, db_type = db_connection
        rows = execute_query(conn, db_type, f"""
            SELECT DISTINCT age_bucket FROM {SCHEMA}.int_receipt_layers
            WHERE age_bucket NOT IN ('Current (0-30)', 'Aging (31-90)', 'Slow (91-180)', 'Obsolete (180+)')
        """)
        assert len(rows) == 0, f"Invalid age buckets: {[r[0] for r in rows]}"


# =============================================================================
# Pick Consumption Tests
# =============================================================================

class TestPickConsumption:
    """Test int_pick_consumption model."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.int_pick_consumption LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.int_pick_consumption LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['pick_id', 'warehouse_id', 'variant_id', 'pick_timestamp', 'pick_date',
                    'pick_qty', 'consumption_start', 'consumption_end']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_consumption_start_begins_at_zero(self, db_connection):
        """First pick per warehouse-variant must have consumption_start = 0."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            WITH first_picks AS (
                SELECT warehouse_id, variant_id, MIN(consumption_start) as min_start
                FROM {SCHEMA}.int_pick_consumption
                GROUP BY warehouse_id, variant_id
            )
            SELECT COUNT(*) FROM first_picks WHERE min_start != 0
        """)
        assert int(result) == 0, f"{result} warehouse-variant combinations don't start at 0"

    def test_consumption_end_equals_start_plus_qty(self, db_connection):
        """consumption_end MUST equal consumption_start + pick_qty."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_pick_consumption
            WHERE ABS(consumption_end - consumption_start - pick_qty) > 0.001
        """)
        assert int(result) == 0, f"{result} rows violate consumption calculation"


# =============================================================================
# FIFO Allocation Tests - STRICT
# =============================================================================

class TestFIFOAllocation:
    """Test int_fifo_allocation model with STRICT FIFO validation."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.int_fifo_allocation LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.int_fifo_allocation LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['pick_id', 'pick_timestamp', 'pick_date', 'warehouse_id', 'variant_id',
                    'receipt_id', 'receipt_unit_cost', 'allocated_qty', 'allocation_cost',
                    'pick_total_qty', 'total_available_before_pick', 'is_fully_fulfilled']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_no_future_receipt_consumption(self, db_connection):
        """ZERO picks can consume from receipts that occurred after the pick. STRICT."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA}.int_fifo_allocation a
            JOIN {SCHEMA}.int_receipt_layers r
                ON a.receipt_id = r.receipt_id
                AND a.warehouse_id = r.warehouse_id
                AND a.variant_id = r.variant_id
            WHERE a.allocated_qty > 0
            AND r.receipt_timestamp >= a.pick_timestamp
        """)
        assert int(result) == 0, f"CRITICAL: {result} picks consume from future receipts"

    def test_strict_fifo_order_no_violations(self, db_connection):
        """Verify allocated_qty matches the expected overlap calculation."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            WITH allocation_check AS (
                SELECT
                    a.pick_id,
                    a.receipt_id,
                    a.allocated_qty,
                    r.cumulative_qty_before as receipt_start,
                    r.cumulative_qty_after as receipt_end,
                    p.consumption_start,
                    p.consumption_end,
                    -- Expected allocation is the overlap
                    GREATEST(0,
                        LEAST(r.cumulative_qty_after, p.consumption_end) -
                        GREATEST(r.cumulative_qty_before, p.consumption_start)
                    ) as expected_qty
                FROM {SCHEMA}.int_fifo_allocation a
                JOIN {SCHEMA}.int_receipt_layers r
                    ON a.receipt_id = r.receipt_id
                    AND a.warehouse_id = r.warehouse_id
                    AND a.variant_id = r.variant_id
                JOIN {SCHEMA}.int_pick_consumption p
                    ON a.pick_id = p.pick_id
                    AND a.warehouse_id = p.warehouse_id
                    AND a.variant_id = p.variant_id
                WHERE a.allocated_qty > 0
            )
            SELECT COUNT(*) as violations
            FROM allocation_check
            WHERE ABS(allocated_qty - expected_qty) > 0.01
        """)
        assert int(result) == 0, f"FIFO VIOLATED: {result} allocations don't match expected overlap"

    def test_allocated_qty_non_negative(self, db_connection):
        """All allocated quantities must be non-negative."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_fifo_allocation WHERE allocated_qty < 0
        """)
        assert int(result) == 0, f"Found {result} negative allocated quantities"

    def test_allocation_cost_calculation(self, db_connection):
        """allocation_cost MUST equal allocated_qty * receipt_unit_cost."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.int_fifo_allocation
            WHERE allocated_qty > 0
            AND ABS(allocation_cost - allocated_qty * receipt_unit_cost) > 0.01
        """)
        assert int(result) == 0, f"{result} rows have incorrect allocation_cost"


# =============================================================================
# FIFO COGS Monthly Tests
# =============================================================================

class TestFIFOCOGSMonthly:
    """Test fifo_cogs_monthly model."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.fifo_cogs_monthly LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.fifo_cogs_monthly LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['year_month', 'category_name', 'warehouse_id', 'total_picks',
                    'total_units_requested', 'total_units_fulfilled', 'total_units_unfulfilled',
                    'total_cogs', 'avg_fifo_unit_cost', 'fulfillment_rate',
                    'pick_count_fully_fulfilled', 'pick_count_partial']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_year_month_format(self, db_connection):
        """year_month must be YYYY-MM format."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            query = f"""
                SELECT COUNT(*) FROM {SCHEMA}.fifo_cogs_monthly
                WHERE NOT REGEXP_LIKE(year_month, '^[0-9]{{4}}-[0-9]{{2}}$')
            """
        else:
            query = f"""
                SELECT COUNT(*) FROM {SCHEMA}.fifo_cogs_monthly
                WHERE year_month NOT SIMILAR TO '[0-9]{{4}}-[0-9]{{2}}'
            """
        result = execute_scalar(conn, db_type, query)
        assert int(result) == 0, "Invalid year_month format found"

    def test_unfulfilled_calculation(self, db_connection):
        """total_units_unfulfilled must equal requested - fulfilled."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.fifo_cogs_monthly
            WHERE ABS(total_units_unfulfilled - (total_units_requested - total_units_fulfilled)) > 0.1
        """)
        assert int(result) == 0, "Unfulfilled calculation incorrect"

    def test_fulfillment_rate_range(self, db_connection):
        """fulfillment_rate must be between 0 and 1."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.fifo_cogs_monthly
            WHERE fulfillment_rate < 0 OR fulfillment_rate > 1
        """)
        assert int(result) == 0, "fulfillment_rate out of range"

    def test_pick_counts_sum_to_total(self, db_connection):
        """pick_count_fully_fulfilled + pick_count_partial must equal total_picks."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.fifo_cogs_monthly
            WHERE pick_count_fully_fulfilled + pick_count_partial != total_picks
        """)
        assert int(result) == 0, "Pick counts don't sum to total"


# =============================================================================
# Ending Inventory Tests
# =============================================================================

class TestEndingInventory:
    """Test ending_inventory_valuation model."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.ending_inventory_valuation LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.ending_inventory_valuation LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['warehouse_id', 'variant_id', 'category_name', 'sku', 'total_units_remaining',
                    'total_value', 'weighted_avg_cost', 'layer_count', 'oldest_layer_date',
                    'newest_layer_date', 'avg_days_in_inventory', 'current_units', 'aging_units',
                    'slow_units', 'obsolete_units', 'obsolete_value']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_positive_remaining(self, db_connection):
        """All rows must have positive remaining inventory."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.ending_inventory_valuation WHERE total_units_remaining <= 0
        """)
        assert int(result) == 0, "Found non-positive remaining inventory"

    def test_weighted_avg_cost_calculation(self, db_connection):
        """weighted_avg_cost must equal total_value / total_units_remaining."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.ending_inventory_valuation
            WHERE ABS(weighted_avg_cost - total_value / total_units_remaining) > 0.1
        """)
        assert int(result) == 0, "weighted_avg_cost calculation incorrect"

    def test_age_buckets_sum_to_total(self, db_connection):
        """Age bucket units must sum to total_units_remaining."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.ending_inventory_valuation
            WHERE ABS((current_units + aging_units + slow_units + obsolete_units) - total_units_remaining) > 0.1
        """)
        assert int(result) == 0, "Age bucket sums don't match total"


# =============================================================================
# Inventory Turnover Tests
# =============================================================================

class TestInventoryTurnover:
    """Test inventory_turnover_analysis model."""

    def test_required_columns(self, db_connection):
        """Check required columns exist."""
        conn, db_type = db_connection
        if db_type == 'snowflake':
            cursor = conn.cursor()
            cursor.execute(f"SELECT * FROM {SCHEMA}.inventory_turnover_analysis LIMIT 1")
            actual = [col[0].lower() for col in cursor.description]
            cursor.fetchall()
        else:
            desc = conn.execute(f"SELECT * FROM {SCHEMA}.inventory_turnover_analysis LIMIT 1").description
            actual = [col[0].lower() for col in desc]
        required = ['warehouse_id', 'category_name', 'total_receipts_qty', 'total_picks_qty',
                    'total_cogs', 'ending_inventory_qty', 'ending_inventory_value',
                    'avg_inventory_value', 'inventory_turnover_ratio', 'days_inventory_outstanding',
                    'fulfillment_efficiency', 'slow_moving_flag']
        for col in required:
            assert col in actual, f"Missing column: {col}"

    def test_slow_moving_flag_logic(self, db_connection):
        """slow_moving_flag must be TRUE when DIO > 90 or turnover < 2."""
        conn, db_type = db_connection
        # Use integer comparison (0/1) for cross-DB compatibility
        # DuckDB booleans: false = 0, true = 1; Snowflake stores as integer 0/1
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM {SCHEMA}.inventory_turnover_analysis
            WHERE CAST(slow_moving_flag AS INTEGER) = 0
            AND ((days_inventory_outstanding IS NOT NULL AND days_inventory_outstanding > 90)
                 OR (inventory_turnover_ratio IS NOT NULL AND inventory_turnover_ratio < 2))
        """)
        assert int(result) == 0, "slow_moving_flag logic incorrect"


# =============================================================================
# Cross-Model Consistency Tests - STRICT
# =============================================================================

class TestDataConsistency:
    """Test cross-model data consistency with strict validation."""

    def test_allocation_matches_cogs_fulfilled(self, db_connection):
        """Total allocated in allocations MUST match fulfilled in COGS."""
        conn, db_type = db_connection
        alloc = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(allocated_qty), 2) FROM {SCHEMA}.int_fifo_allocation
        """)
        cogs = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(total_units_fulfilled), 2) FROM {SCHEMA}.fifo_cogs_monthly
        """)
        assert abs(float(alloc) - float(cogs)) < 1, \
            f"Mismatch: allocations={alloc}, COGS fulfilled={cogs}"

    def test_cogs_total_matches_allocation_cost(self, db_connection):
        """Total COGS must match sum of allocation costs."""
        conn, db_type = db_connection
        alloc_cost = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(allocation_cost), 2) FROM {SCHEMA}.int_fifo_allocation
        """)
        cogs_total = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(total_cogs), 2) FROM {SCHEMA}.fifo_cogs_monthly
        """)
        assert abs(float(alloc_cost) - float(cogs_total)) < 1, \
            f"COGS mismatch: allocation_cost={alloc_cost}, total_cogs={cogs_total}"

    def test_ending_inventory_positive_value(self, db_connection):
        """Ending inventory must have positive total value."""
        conn, db_type = db_connection
        result = execute_scalar(conn, db_type, f"""
            SELECT ROUND(SUM(total_value), 2) FROM {SCHEMA}.ending_inventory_valuation
        """)
        assert result is not None and float(result) > 0, "No positive ending inventory value"


# =============================================================================
# Expected Values Tests
# =============================================================================

def load_expected_values():
    """Load expected values from private_data/expected_results.txt (or Snowflake variant)."""
    expected = {}
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    base_dir = os.path.join(os.path.dirname(__file__), 'private_data')
    if db_type == 'snowflake':
        expected_file = os.path.join(base_dir, 'expected_results_snowflake.txt')
        if not os.path.exists(expected_file):
            expected_file = os.path.join(base_dir, 'expected_results.txt')
    else:
        expected_file = os.path.join(base_dir, 'expected_results.txt')
    if os.path.exists(expected_file):
        with open(expected_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    expected[key.strip()] = value.strip()
    return expected


def _is_snowflake():
    """Check if running on Snowflake backend."""
    return os.environ.get('DB_TYPE', 'duckdb').lower() == 'snowflake'


class TestExpectedValues:
    """Test against expected ground truth values from reference solution.

    Values are loaded from backend-specific expected_results files.
    Some keys may be absent from the Snowflake file due to column name
    differences; those tests pass silently when the key is missing.
    """

    @pytest.fixture(scope="class")
    def expected(self):
        """Load expected values."""
        return load_expected_values()

    def test_fifo_cogs_row_count(self, db_connection, expected):
        """fifo_cogs_monthly must have expected row count."""
        conn, db_type = db_connection
        if 'FIFO_COGS_ROW_COUNT' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.fifo_cogs_monthly")
        expected_count = int(expected['FIFO_COGS_ROW_COUNT'])
        assert int(result) == expected_count, f"Row count {result} != expected {expected_count}"

    def test_fifo_cogs_unique_months(self, db_connection, expected):
        """fifo_cogs_monthly must have expected unique months."""
        conn, db_type = db_connection
        if 'FIFO_COGS_UNIQUE_MONTHS' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT COUNT(DISTINCT year_month) FROM {SCHEMA}.fifo_cogs_monthly")
        expected_months = int(expected['FIFO_COGS_UNIQUE_MONTHS'])
        assert int(result) == expected_months, f"Unique months {result} != expected {expected_months}"

    def test_fifo_cogs_total_cogs(self, db_connection, expected):
        """fifo_cogs_monthly total COGS must match expected."""
        conn, db_type = db_connection
        if 'FIFO_COGS_TOTAL_COGS' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(SUM(total_cogs), 2) FROM {SCHEMA}.fifo_cogs_monthly")
        expected_cogs = float(expected['FIFO_COGS_TOTAL_COGS'])
        assert abs(float(result) - expected_cogs) < 1, f"Total COGS {result} != expected {expected_cogs}"

    def test_fifo_cogs_total_fulfilled(self, db_connection, expected):
        """fifo_cogs_monthly total fulfilled must match expected."""
        conn, db_type = db_connection
        if 'FIFO_COGS_TOTAL_FULFILLED' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(SUM(total_units_fulfilled), 2) FROM {SCHEMA}.fifo_cogs_monthly")
        expected_fulfilled = float(expected['FIFO_COGS_TOTAL_FULFILLED'])
        assert abs(float(result) - expected_fulfilled) < 1, f"Total fulfilled {result} != expected {expected_fulfilled}"

    def test_fifo_cogs_total_unfulfilled(self, db_connection, expected):
        """fifo_cogs_monthly total unfulfilled must match expected."""
        conn, db_type = db_connection
        if 'FIFO_COGS_TOTAL_UNFULFILLED' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(SUM(total_units_unfulfilled), 2) FROM {SCHEMA}.fifo_cogs_monthly")
        expected_unfulfilled = float(expected['FIFO_COGS_TOTAL_UNFULFILLED'])
        assert abs(float(result) - expected_unfulfilled) < 1, f"Total unfulfilled {result} != expected {expected_unfulfilled}"

    def test_fifo_cogs_avg_fulfillment_rate(self, db_connection, expected):
        """fifo_cogs_monthly avg fulfillment rate must match expected."""
        conn, db_type = db_connection
        if 'FIFO_COGS_AVG_FULFILLMENT_RATE' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(AVG(fulfillment_rate), 4) FROM {SCHEMA}.fifo_cogs_monthly")
        expected_rate = float(expected['FIFO_COGS_AVG_FULFILLMENT_RATE'])
        assert abs(float(result) - expected_rate) < 0.01, f"Avg fulfillment rate {result} != expected {expected_rate}"

    def test_ending_inv_row_count(self, db_connection, expected):
        """ending_inventory_valuation must have expected row count."""
        conn, db_type = db_connection
        if 'ENDING_INV_ROW_COUNT' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.ending_inventory_valuation")
        expected_count = int(expected['ENDING_INV_ROW_COUNT'])
        assert int(result) == expected_count, f"Row count {result} != expected {expected_count}"

    def test_ending_inv_total_remaining(self, db_connection, expected):
        """ending_inventory_valuation total remaining must match expected."""
        conn, db_type = db_connection
        if 'ENDING_INV_TOTAL_REMAINING' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(SUM(total_units_remaining), 2) FROM {SCHEMA}.ending_inventory_valuation")
        expected_remaining = float(expected['ENDING_INV_TOTAL_REMAINING'])
        assert abs(float(result) - expected_remaining) < 1, f"Total remaining {result} != expected {expected_remaining}"

    def test_ending_inv_total_value(self, db_connection, expected):
        """ending_inventory_valuation total value must match expected."""
        conn, db_type = db_connection
        if 'ENDING_INV_TOTAL_VALUE' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(SUM(total_value), 2) FROM {SCHEMA}.ending_inventory_valuation")
        expected_value = float(expected['ENDING_INV_TOTAL_VALUE'])
        assert abs(float(result) - expected_value) < 1, f"Total value {result} != expected {expected_value}"

    def test_receipt_layers_row_count(self, db_connection, expected):
        """int_receipt_layers must have expected row count."""
        conn, db_type = db_connection
        if 'RECEIPT_LAYERS_ROW_COUNT' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.int_receipt_layers")
        expected_count = int(expected['RECEIPT_LAYERS_ROW_COUNT'])
        assert int(result) == expected_count, f"Row count {result} != expected {expected_count}"

    def test_pick_allocation_row_count(self, db_connection, expected):
        """int_fifo_allocation must have expected row count."""
        conn, db_type = db_connection
        if 'PICK_ALLOC_ROW_COUNT' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.int_fifo_allocation")
        expected_count = int(expected['PICK_ALLOC_ROW_COUNT'])
        assert int(result) == expected_count, f"Row count {result} != expected {expected_count}"

    def test_pick_allocation_total_allocated(self, db_connection, expected):
        """int_fifo_allocation total allocated must match expected."""
        conn, db_type = db_connection
        if 'PICK_ALLOC_TOTAL_ALLOCATED' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT ROUND(SUM(allocated_qty), 2) FROM {SCHEMA}.int_fifo_allocation")
        expected_allocated = float(expected['PICK_ALLOC_TOTAL_ALLOCATED'])
        assert abs(float(result) - expected_allocated) < 1, f"Total allocated {result} != expected {expected_allocated}"

    def test_pick_allocation_insufficient_count(self, db_connection, expected):
        """int_fifo_allocation insufficient fulfillment count must match expected."""
        conn, db_type = db_connection
        if 'PICK_ALLOC_INSUFFICIENT_COUNT' not in expected:
            return
        result = execute_scalar(conn, db_type, f"SELECT COUNT(*) FROM {SCHEMA}.int_fifo_allocation WHERE CAST(is_fully_fulfilled AS INTEGER) = 0")
        expected_count = int(expected['PICK_ALLOC_INSUFFICIENT_COUNT'])
        assert int(result) == expected_count, f"Insufficient count {result} != expected {expected_count}"
