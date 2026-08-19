"""
Test verifier for Three-Way Purchase Order Matching with Risk Scoring.
Validates PO-to-Receipt-to-Invoice matching logic, variance calculations,
risk scoring, and exception handling.

Tests use the actual data from staging models to validate correctness.
"""
import subprocess
import os
import re
from decimal import Decimal, ROUND_HALF_UP


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
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    """
    Execute a shell command and return the result.

    Args:
        cmd: Shell command to execute as a string
        cwd: Working directory for command execution

    Returns:
        subprocess.CompletedProcess with stdout, stderr, and returncode
    """
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:500]}")
    return result


def require(condition, msg):
    """
    Assert that a condition is true, raising AssertionError with message if false.

    Args:
        condition: Boolean condition to evaluate
        msg: Error message to display if condition is false

    Raises:
        AssertionError: If condition evaluates to false
    """
    if not condition:
        raise AssertionError(msg)


def run_dbt_pipeline():
    """
    Execute the dbt pipeline to build the three_way_match model.

    Runs dbt to materialize the three_way_match model and its dependencies.
    Raises AssertionError if the dbt run fails.
    """
    result = run_cmd("dbt run --select +three_way_match")
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")


def get_connection():
    """
    Establish a database connection using dual-backend infrastructure.

    Returns:
        tuple: (connection, db_type) where db_type is 'duckdb' or 'snowflake'
    """
    return get_db_connection()


def test_model_exists():
    """
    Verify that the three_way_match model was created successfully.

    Checks that the model exists in the main schema and contains data.
    """
    run_dbt_pipeline()
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT COUNT(*) as cnt
        FROM information_schema.tables
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'three_way_match'
    """)
    require(result[0][0] == 1, "three_way_match model does not exist")

    row_count = execute_query(conn, db_type, "SELECT COUNT(*) FROM main.three_way_match")
    require(row_count[0][0] > 0, "three_way_match model has no data")
    print(f"Model exists with {row_count[0][0]} rows")
    conn.close()


def test_required_columns_present():
    """
    Validate that all required columns are present in the output model.

    Checks for presence of all 38 required columns as specified
    in the task requirements.
    """
    conn, db_type = get_connection()

    cols = execute_query(conn, db_type, """
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'three_way_match'
    """)
    col_names = {c[0].lower() for c in cols}

    required_columns = {
        'match_id', 'po_id', 'po_number', 'po_line_id', 'supplier_id',
        'supplier_name', 'supplier_rating', 'variant_id', 'sku', 'po_quantity',
        'po_unit_price', 'po_line_total', 'receipt_quantity', 'accepted_quantity',
        'rejected_quantity', 'rejection_rate', 'invoice_quantity', 'invoice_unit_price',
        'invoice_line_total', 'quantity_variance', 'quantity_variance_pct',
        'price_variance', 'price_variance_pct', 'total_variance', 'expected_amount',
        'quantity_match_status', 'price_match_status', 'overall_match_status',
        'exception_reasons', 'exception_count', 'risk_score', 'risk_category',
        'recommended_action', 'days_to_invoice', 'days_receipt_to_invoice',
        'receipt_count', 'invoice_count'
    }

    missing = required_columns - col_names
    require(not missing, f"Missing required columns: {missing}")
    print(f"All {len(required_columns)} required columns present")
    conn.close()


def test_match_id_uniqueness():
    """
    Verify that match_id values are unique across all records.

    Each match record should have a unique identifier to prevent
    duplicate processing.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, COUNT(*) as cnt
        FROM main.three_way_match
        GROUP BY match_id
        HAVING COUNT(*) > 1
        LIMIT 5
    """)

    require(len(result) == 0, f"Duplicate match_id values found: {result}")
    print("All match_id values are unique")
    conn.close()


def test_quantity_variance_calculation():
    """
    Verify that quantity variance is calculated correctly.

    Quantity variance should equal invoice_quantity minus accepted_quantity.
    Allows for small rounding tolerance of 0.01.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_quantity, accepted_quantity, quantity_variance
        FROM main.three_way_match
        WHERE ABS(quantity_variance - (invoice_quantity - accepted_quantity)) > 0.01
        AND invoice_quantity IS NOT NULL
        AND accepted_quantity IS NOT NULL
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Quantity variance calculation errors: {result}")
    print("Quantity variance calculations are correct")
    conn.close()


def test_quantity_variance_pct_calculation():
    """
    Verify that quantity variance percentage is calculated correctly.

    Formula: (invoice_qty - accepted_qty) / accepted_qty * 100
    Must handle division by zero appropriately.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_quantity, accepted_quantity, quantity_variance_pct
        FROM main.three_way_match
        WHERE accepted_quantity > 0
        AND invoice_quantity IS NOT NULL
        AND ABS(quantity_variance_pct - ((invoice_quantity - accepted_quantity) / accepted_quantity * 100)) > 0.1
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Quantity variance percentage calculation errors: {result}")
    print("Quantity variance percentage calculations are correct")
    conn.close()


def test_price_variance_calculation():
    """
    Verify that price variance is calculated correctly.

    Price variance should equal invoice_unit_price minus po_unit_price.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_unit_price, po_unit_price, price_variance
        FROM main.three_way_match
        WHERE ABS(price_variance - (invoice_unit_price - po_unit_price)) > 0.01
        AND invoice_unit_price IS NOT NULL
        AND po_unit_price IS NOT NULL
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Price variance calculation errors: {result}")
    print("Price variance calculations are correct")
    conn.close()


def test_price_variance_pct_calculation():
    """
    Verify that price variance percentage is calculated correctly.

    Formula: (inv_price - po_price) / po_price * 100
    Must handle division by zero appropriately.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_unit_price, po_unit_price, price_variance_pct
        FROM main.three_way_match
        WHERE po_unit_price > 0
        AND invoice_unit_price IS NOT NULL
        AND ABS(price_variance_pct - ((invoice_unit_price - po_unit_price) / po_unit_price * 100)) > 0.1
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Price variance percentage calculation errors: {result}")
    print("Price variance percentage calculations are correct")
    conn.close()


def test_total_variance_calculation():
    """
    Verify that total variance is calculated correctly.

    Formula: invoice_line_total - (accepted_quantity * po_unit_price)
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_line_total, accepted_quantity, po_unit_price, total_variance
        FROM main.three_way_match
        WHERE invoice_line_total IS NOT NULL
        AND accepted_quantity IS NOT NULL
        AND po_unit_price IS NOT NULL
        AND ABS(total_variance - (invoice_line_total - (accepted_quantity * po_unit_price))) > 0.01
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Total variance calculation errors: {result}")
    print("Total variance calculations are correct")
    conn.close()


def test_quantity_match_status_values():
    """
    Verify that quantity_match_status contains only valid values.

    Valid values: EXACT_MATCH, WITHIN_TOLERANCE, UNDER_BILLED,
    OVER_BILLED, NO_RECEIPT, PARTIAL_RECEIPT
    """
    conn, db_type = get_connection()

    valid_statuses = {
        'EXACT_MATCH', 'WITHIN_TOLERANCE', 'UNDER_BILLED',
        'OVER_BILLED', 'NO_RECEIPT', 'PARTIAL_RECEIPT'
    }

    result = execute_query(conn, db_type, """
        SELECT DISTINCT quantity_match_status
        FROM main.three_way_match
        WHERE quantity_match_status IS NOT NULL
    """)

    actual_statuses = {r[0] for r in result}
    invalid = actual_statuses - valid_statuses

    require(len(invalid) == 0,
            f"Invalid quantity_match_status values: {invalid}")
    print(f"Quantity match status values are valid: {actual_statuses}")
    conn.close()


def test_price_match_status_values():
    """
    Verify that price_match_status contains only valid values.

    Valid values: EXACT_MATCH, WITHIN_TOLERANCE, PRICE_DECREASE,
    PRICE_INCREASE, NO_PO_PRICE
    """
    conn, db_type = get_connection()

    valid_statuses = {
        'EXACT_MATCH', 'WITHIN_TOLERANCE', 'PRICE_DECREASE',
        'PRICE_INCREASE', 'NO_PO_PRICE'
    }

    result = execute_query(conn, db_type, """
        SELECT DISTINCT price_match_status
        FROM main.three_way_match
        WHERE price_match_status IS NOT NULL
    """)

    actual_statuses = {r[0] for r in result}
    invalid = actual_statuses - valid_statuses

    require(len(invalid) == 0,
            f"Invalid price_match_status values: {invalid}")
    print(f"Price match status values are valid: {actual_statuses}")
    conn.close()


def test_overall_match_status_values():
    """
    Verify that overall_match_status contains only valid values.

    Valid values: APPROVED, REVIEW_REQUIRED, BLOCKED,
    PENDING_RECEIPT, UNMATCHED
    """
    conn, db_type = get_connection()

    valid_statuses = {
        'APPROVED', 'REVIEW_REQUIRED', 'BLOCKED',
        'PENDING_RECEIPT', 'UNMATCHED'
    }

    result = execute_query(conn, db_type, """
        SELECT DISTINCT overall_match_status
        FROM main.three_way_match
        WHERE overall_match_status IS NOT NULL
    """)

    actual_statuses = {r[0] for r in result}
    invalid = actual_statuses - valid_statuses

    require(len(invalid) == 0,
            f"Invalid overall_match_status values: {invalid}")
    print(f"Overall match status values are valid: {actual_statuses}")
    conn.close()


def test_recommended_action_values():
    """
    Verify that recommended_action contains only valid values.

    Valid values: PAY_IMMEDIATELY, PAY_WITH_ADJUSTMENT, HOLD_FOR_REVIEW,
    REQUEST_CREDIT_MEMO, CONTACT_SUPPLIER, WAIT_FOR_RECEIPT, ESCALATE_TO_MANAGEMENT
    """
    conn, db_type = get_connection()

    valid_actions = {
        'PAY_IMMEDIATELY', 'PAY_WITH_ADJUSTMENT', 'HOLD_FOR_REVIEW',
        'REQUEST_CREDIT_MEMO', 'CONTACT_SUPPLIER', 'WAIT_FOR_RECEIPT',
        'ESCALATE_TO_MANAGEMENT'
    }

    result = execute_query(conn, db_type, """
        SELECT DISTINCT recommended_action
        FROM main.three_way_match
        WHERE recommended_action IS NOT NULL
    """)

    actual_actions = {r[0] for r in result}
    invalid = actual_actions - valid_actions

    require(len(invalid) == 0,
            f"Invalid recommended_action values: {invalid}")
    print(f"Recommended action values are valid: {actual_actions}")
    conn.close()


def test_quantity_exact_match_logic():
    """
    Verify that EXACT_MATCH status is applied when quantities are equal.

    When invoice_quantity equals accepted_quantity, status should be EXACT_MATCH.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_quantity, accepted_quantity, quantity_match_status
        FROM main.three_way_match
        WHERE invoice_quantity = accepted_quantity
        AND accepted_quantity > 0
        AND quantity_match_status != 'EXACT_MATCH'
    """)

    require(len(result) == 0,
            f"Exact quantity matches not flagged as EXACT_MATCH (showing first 5): {result[:5]}")
    print("Quantity exact match logic is correct")
    conn.close()


def test_quantity_within_tolerance_logic():
    """
    Verify that WITHIN_TOLERANCE is applied correctly for quantity variances.

    Tolerance: within +/-2% AND within +/-5 units (both conditions).
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_quantity, accepted_quantity, quantity_variance_pct, quantity_match_status
        FROM main.three_way_match
        WHERE accepted_quantity > 0
        AND invoice_quantity != accepted_quantity
        AND ABS(quantity_variance_pct) <= 2.0
        AND ABS(invoice_quantity - accepted_quantity) <= 5.0
        AND quantity_match_status NOT IN ('EXACT_MATCH', 'WITHIN_TOLERANCE')
    """)

    require(len(result) == 0,
            f"Within tolerance quantity variances not flagged correctly (showing first 5): {result[:5]}")
    print("Quantity within tolerance logic is correct")
    conn.close()


def test_price_exact_match_logic():
    """
    Verify that EXACT_MATCH status is applied when prices are equal.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_unit_price, po_unit_price, price_match_status
        FROM main.three_way_match
        WHERE invoice_unit_price = po_unit_price
        AND po_unit_price > 0
        AND price_match_status != 'EXACT_MATCH'
    """)

    require(len(result) == 0,
            f"Exact price matches not flagged as EXACT_MATCH (showing first 5): {result[:5]}")
    print("Price exact match logic is correct")
    conn.close()


def test_price_within_tolerance_logic():
    """
    Verify that WITHIN_TOLERANCE is applied correctly for price variances.

    Tolerance: within +/-1% AND within +/-$0.50 (both conditions).
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_unit_price, po_unit_price, price_variance_pct, price_match_status
        FROM main.three_way_match
        WHERE po_unit_price > 0
        AND invoice_unit_price != po_unit_price
        AND ABS(price_variance_pct) <= 1.0
        AND ABS(invoice_unit_price - po_unit_price) <= 0.50
        AND price_match_status NOT IN ('EXACT_MATCH', 'WITHIN_TOLERANCE')
    """)

    require(len(result) == 0,
            f"Within tolerance price variances not flagged correctly (showing first 5): {result[:5]}")
    print("Price within tolerance logic is correct")
    conn.close()


def test_approved_status_logic():
    """
    Verify that APPROVED overall status is correctly assigned.

    APPROVED should only be assigned when both quantity and price
    are EXACT_MATCH or WITHIN_TOLERANCE.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, quantity_match_status, price_match_status, overall_match_status
        FROM main.three_way_match
        WHERE overall_match_status = 'APPROVED'
        AND (
            quantity_match_status NOT IN ('EXACT_MATCH', 'WITHIN_TOLERANCE')
            OR price_match_status NOT IN ('EXACT_MATCH', 'WITHIN_TOLERANCE')
        )
        LIMIT 5
    """)

    require(len(result) == 0,
            f"APPROVED status assigned incorrectly: {result}")
    print("Approved status logic is correct")
    conn.close()


def test_blocked_high_price_increase():
    """
    Verify that BLOCKED status is applied for price increases over 5%.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, price_variance_pct, overall_match_status
        FROM main.three_way_match
        WHERE price_variance_pct > 5.0
        AND overall_match_status != 'BLOCKED'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"High price increases not BLOCKED: {result}")
    print("Blocked for high price increase logic is correct")
    conn.close()


def test_blocked_high_quantity_overbilled():
    """
    Verify that BLOCKED status is applied for quantity over-billed by more than 10%.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, quantity_variance_pct, overall_match_status
        FROM main.three_way_match
        WHERE quantity_variance_pct > 10.0
        AND overall_match_status != 'BLOCKED'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"High quantity overbilling not BLOCKED: {result}")
    print("Blocked for high quantity overbilling logic is correct")
    conn.close()


def test_blocked_large_variance_amount():
    """
    Verify BLOCKED status for invoices over $1000 with any variance over tolerance.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_line_total, quantity_match_status, price_match_status, overall_match_status
        FROM main.three_way_match
        WHERE invoice_line_total > 1000
        AND (
            quantity_match_status NOT IN ('EXACT_MATCH', 'WITHIN_TOLERANCE')
            OR price_match_status NOT IN ('EXACT_MATCH', 'WITHIN_TOLERANCE')
        )
        AND overall_match_status != 'BLOCKED'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Large invoices with variances not BLOCKED: {result}")
    print("Blocked for large variance amounts logic is correct")
    conn.close()


def test_exception_reasons_format():
    """
    Verify that exception_reasons follows the pipe-delimited format.

    Should contain valid reason codes or 'NONE'.
    """
    conn, db_type = get_connection()

    valid_codes = {'QTY_OVER', 'QTY_UNDER', 'QTY_PARTIAL', 'QTY_NONE',
                   'PRC_HIGH', 'PRC_LOW', 'PRC_MISSING', 'AMT_LARGE',
                   'TIMING_LATE', 'HIGH_REJECT', 'MULTI_INVOICE',
                   'LOW_SUPPLIER_RATING', 'NONE'}

    result = execute_query(conn, db_type, """
        SELECT exception_reasons FROM main.three_way_match
    """)

    for row in result:
        reasons = row[0]
        if reasons:
            parts = reasons.split('|')
            for part in parts:
                part = part.strip()
                require(part in valid_codes,
                        f"Invalid exception code '{part}' in: {reasons}")

    print("Exception reasons format is correct")
    conn.close()


def test_pay_immediately_with_approved():
    """
    Verify that PAY_IMMEDIATELY is recommended for APPROVED matches.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, overall_match_status, recommended_action
        FROM main.three_way_match
        WHERE overall_match_status = 'APPROVED'
        AND recommended_action != 'PAY_IMMEDIATELY'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"APPROVED matches not recommending PAY_IMMEDIATELY: {result}")
    print("Pay immediately for approved matches logic is correct")
    conn.close()


def test_days_to_invoice_calculation():
    """
    Verify that days_to_invoice is calculated correctly.

    May be negative for backdated invoices. Validates calculation exists.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT COUNT(*)
        FROM main.three_way_match
        WHERE days_to_invoice IS NOT NULL
    """)

    require(result[0][0] > 0,
            "No days_to_invoice values were calculated")
    print(f"Days to invoice calculations present for {result[0][0]} records")
    conn.close()


def test_no_receipt_handling():
    """
    Verify that records with no receipts are handled correctly.

    quantity_match_status should be NO_RECEIPT when no receipts exist.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, receipt_quantity, quantity_match_status
        FROM main.three_way_match
        WHERE (receipt_quantity IS NULL OR receipt_quantity = 0)
        AND quantity_match_status != 'NO_RECEIPT'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Missing receipts not flagged as NO_RECEIPT: {result}")
    print("No receipt handling is correct")
    conn.close()


def test_aggregated_receipt_quantities():
    """
    Verify that receipt quantities are aggregated correctly per PO line.

    Multiple receipt lines for the same PO line should be summed.

    Note: Uses PROCUREMENT schema tables directly for validation as the
    source of truth, independent of the agent's staging model implementation.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        WITH receipt_totals AS (
            SELECT
                prl.po_line_id,
                SUM(COALESCE(prl.quantity_received, 0)) as calculated_receipt_qty
            FROM PROCUREMENT.PURCHASE_ORDER_RECEIPT_LINES prl
            INNER JOIN PROCUREMENT.PURCHASE_ORDER_RECEIPTS por
                ON prl.receipt_id = por.receipt_id
            GROUP BY prl.po_line_id
        )
        SELECT
            t.match_id, t.po_line_id, t.receipt_quantity, rt.calculated_receipt_qty
        FROM main.three_way_match t
        JOIN receipt_totals rt ON t.po_line_id = rt.po_line_id
        WHERE t.receipt_quantity IS NOT NULL
        AND ABS(t.receipt_quantity - rt.calculated_receipt_qty) > 0.01
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Receipt quantity aggregation mismatch: {result}")
    print("Receipt quantities are aggregated correctly")
    conn.close()


def test_supplier_name_populated():
    """
    Verify that supplier_name is populated from the suppliers table.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, supplier_id, supplier_name
        FROM main.three_way_match
        WHERE supplier_id IS NOT NULL
        AND (supplier_name IS NULL OR supplier_name = '')
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Missing supplier names: {result}")
    print("Supplier names are populated correctly")
    conn.close()


def test_amt_large_exception():
    """
    Verify that AMT_LARGE exception is flagged for variances over $500.

    Exception should be present when ABS(total_variance) > 500.
    Checks for the presence of 'AMT_LARGE' code in exception_reasons.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, total_variance, exception_reasons
        FROM main.three_way_match
        WHERE ABS(total_variance) > 500
        AND (
            exception_reasons IS NULL
            OR exception_reasons = ''
            OR POSITION('AMT_LARGE' IN exception_reasons) = 0
        )
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Large amount variances missing AMT_LARGE exception: {result}")
    print("AMT_LARGE exception flagging is correct")
    conn.close()


def test_timing_late_exception():
    """
    Verify that TIMING_LATE exception is flagged for invoices more than 30 days after receipt.

    Exception should be present when days_receipt_to_invoice > 30.
    Checks for the presence of 'TIMING_LATE' code in exception_reasons.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, days_receipt_to_invoice, exception_reasons
        FROM main.three_way_match
        WHERE days_receipt_to_invoice > 30
        AND (
            exception_reasons IS NULL
            OR exception_reasons = ''
            OR POSITION('TIMING_LATE' IN exception_reasons) = 0
        )
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Late invoices missing TIMING_LATE exception: {result}")
    print("TIMING_LATE exception flagging is correct")
    conn.close()


def test_none_exception_when_clean():
    """
    Verify that exception_reasons is 'NONE' when there are no issues.

    For APPROVED matches, exception_reasons should be 'NONE'.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, overall_match_status, exception_reasons
        FROM main.three_way_match
        WHERE overall_match_status = 'APPROVED'
        AND exception_reasons != 'NONE'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"APPROVED matches with non-NONE exceptions: {result}")
    print("NONE exception for clean matches is correct")
    conn.close()


def test_exception_reasons_only_valid_codes():
    """
    Verify that exception_reasons contains only valid codes and proper delimiters.

    Valid codes: AMT_LARGE, PRC_HIGH, PRC_LOW, PRC_MISSING, QTY_NONE,
                 QTY_OVER, QTY_PARTIAL, QTY_UNDER, TIMING_LATE, HIGH_REJECT,
                 MULTI_INVOICE, LOW_SUPPLIER_RATING, NONE
    Should be pipe-delimited with no extra whitespace.

    This test also validates the mapping between status values and exception codes.
    """
    conn, db_type = get_connection()

    valid_codes = {'QTY_OVER', 'QTY_UNDER', 'QTY_PARTIAL', 'QTY_NONE',
                   'PRC_HIGH', 'PRC_LOW', 'PRC_MISSING', 'AMT_LARGE',
                   'TIMING_LATE', 'HIGH_REJECT', 'MULTI_INVOICE',
                   'LOW_SUPPLIER_RATING', 'NONE'}

    result = execute_query(conn, db_type, """
        SELECT DISTINCT exception_reasons
        FROM main.three_way_match
        WHERE exception_reasons IS NOT NULL
    """)

    invalid_found = []
    for row in result:
        reasons = row[0]
        if reasons and reasons != 'NONE':
            parts = reasons.split('|')
            for part in parts:
                cleaned_part = part.strip()
                if cleaned_part not in valid_codes:
                    invalid_found.append(f"Invalid code '{cleaned_part}' in: {reasons}")

    require(len(invalid_found) == 0,
            f"Invalid exception codes found: {invalid_found[:5]}")
    print("Exception reasons contain only valid codes")
    conn.close()


def test_exception_code_mappings():
    """
    Verify that exception codes are correctly mapped from status values.

    Validates the complete mapping between match status values and exception codes:
    - quantity_match_status -> QTY_* codes
    - price_match_status -> PRC_* codes
    - total_variance -> AMT_LARGE
    - days_receipt_to_invoice -> TIMING_LATE
    """
    conn, db_type = get_connection()

    # Test QTY_OVER mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE quantity_match_status = 'OVER_BILLED'
        AND POSITION('QTY_OVER' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"OVER_BILLED missing QTY_OVER: {result}")

    # Test QTY_UNDER mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE quantity_match_status = 'UNDER_BILLED'
        AND POSITION('QTY_UNDER' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"UNDER_BILLED missing QTY_UNDER: {result}")

    # Test QTY_PARTIAL mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE quantity_match_status = 'PARTIAL_RECEIPT'
        AND POSITION('QTY_PARTIAL' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"PARTIAL_RECEIPT missing QTY_PARTIAL: {result}")

    # Test QTY_NONE mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE quantity_match_status = 'NO_RECEIPT'
        AND POSITION('QTY_NONE' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"NO_RECEIPT missing QTY_NONE: {result}")

    # Test PRC_HIGH mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE price_match_status = 'PRICE_INCREASE'
        AND POSITION('PRC_HIGH' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"PRICE_INCREASE missing PRC_HIGH: {result}")

    # Test PRC_LOW mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE price_match_status = 'PRICE_DECREASE'
        AND POSITION('PRC_LOW' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"PRICE_DECREASE missing PRC_LOW: {result}")

    # Test PRC_MISSING mapping
    result = execute_query(conn, db_type, """
        SELECT match_id FROM main.three_way_match
        WHERE price_match_status = 'NO_PO_PRICE'
        AND POSITION('PRC_MISSING' IN exception_reasons) = 0
        LIMIT 5
    """)
    require(len(result) == 0, f"NO_PO_PRICE missing PRC_MISSING: {result}")

    print("All exception code mappings are correct")
    conn.close()


def test_exact_match_precedence_over_partial():
    """
    Verify that EXACT_MATCH takes precedence over PARTIAL_RECEIPT.

    Critical test: When invoice_quantity = accepted_quantity AND receipt_quantity < po_quantity,
    the status should be EXACT_MATCH, not PARTIAL_RECEIPT.

    This validates the precedence rule clarification.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT
            match_id,
            invoice_quantity,
            accepted_quantity,
            receipt_quantity,
            po_quantity,
            quantity_match_status
        FROM main.three_way_match
        WHERE invoice_quantity = accepted_quantity
        AND accepted_quantity > 0
        AND receipt_quantity < po_quantity
        AND quantity_match_status != 'EXACT_MATCH'
        LIMIT 10
    """)

    require(len(result) == 0,
            f"EXACT_MATCH should take precedence over PARTIAL_RECEIPT: {result}")
    print("EXACT_MATCH precedence over PARTIAL_RECEIPT is correct")
    conn.close()


def test_no_receipt_precedence():
    """
    Verify that NO_RECEIPT takes highest precedence when receipts don't exist.

    When receipt_quantity is NULL or 0, status should be NO_RECEIPT regardless of other conditions.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT
            match_id,
            receipt_quantity,
            quantity_match_status
        FROM main.three_way_match
        WHERE (receipt_quantity IS NULL OR receipt_quantity = 0)
        AND quantity_match_status != 'NO_RECEIPT'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"NO_RECEIPT should be applied when no receipts exist: {result}")
    print("NO_RECEIPT precedence is correct")
    conn.close()


def test_risk_score_range():
    """
    Verify that risk_score is within valid range (0-100).
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, risk_score
        FROM main.three_way_match
        WHERE risk_score IS NOT NULL
        AND (risk_score < 0 OR risk_score > 100)
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Risk scores outside valid range 0-100: {result}")
    print("Risk scores are within valid range")
    conn.close()


def test_risk_category_values():
    """
    Verify that risk_category contains only valid values.

    Valid values: LOW, MEDIUM, HIGH, CRITICAL
    """
    conn, db_type = get_connection()

    valid_categories = {'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'}

    result = execute_query(conn, db_type, """
        SELECT DISTINCT risk_category
        FROM main.three_way_match
        WHERE risk_category IS NOT NULL
    """)

    actual_categories = {r[0] for r in result}
    invalid = actual_categories - valid_categories

    require(len(invalid) == 0,
            f"Invalid risk_category values: {invalid}")
    print(f"Risk category values are valid: {actual_categories}")
    conn.close()


def test_risk_category_matches_score():
    """
    Verify that risk_category correctly corresponds to risk_score.

    LOW: 0-24, MEDIUM: 25-49, HIGH: 50-79, CRITICAL: 80-100
    """
    conn, db_type = get_connection()

    # Check LOW category
    result = execute_query(conn, db_type, """
        SELECT match_id, risk_score, risk_category
        FROM main.three_way_match
        WHERE risk_score >= 0 AND risk_score <= 24
        AND risk_category != 'LOW'
        LIMIT 5
    """)
    require(len(result) == 0, f"LOW category mismatch: {result}")

    # Check MEDIUM category
    result = execute_query(conn, db_type, """
        SELECT match_id, risk_score, risk_category
        FROM main.three_way_match
        WHERE risk_score >= 25 AND risk_score <= 49
        AND risk_category != 'MEDIUM'
        LIMIT 5
    """)
    require(len(result) == 0, f"MEDIUM category mismatch: {result}")

    # Check HIGH category
    result = execute_query(conn, db_type, """
        SELECT match_id, risk_score, risk_category
        FROM main.three_way_match
        WHERE risk_score >= 50 AND risk_score <= 79
        AND risk_category != 'HIGH'
        LIMIT 5
    """)
    require(len(result) == 0, f"HIGH category mismatch: {result}")

    # Check CRITICAL category
    result = execute_query(conn, db_type, """
        SELECT match_id, risk_score, risk_category
        FROM main.three_way_match
        WHERE risk_score >= 80 AND risk_score <= 100
        AND risk_category != 'CRITICAL'
        LIMIT 5
    """)
    require(len(result) == 0, f"CRITICAL category mismatch: {result}")

    print("Risk categories match risk scores correctly")
    conn.close()


def test_supplier_rating_populated():
    """
    Verify that supplier_rating is populated from the suppliers table.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT COUNT(*) FROM main.three_way_match
        WHERE supplier_rating IS NOT NULL
    """)

    require(result[0][0] > 0,
            "No supplier_rating values found - should be populated from suppliers table")
    print(f"Supplier rating is populated for {result[0][0]} records")
    conn.close()


def test_rejection_rate_calculation():
    """
    Verify that rejection_rate is calculated correctly.

    Formula: (rejected_quantity / receipt_quantity) * 100
    Should be 0 when receipt_quantity is 0 or null.
    """
    conn, db_type = get_connection()

    # Check calculation where receipt_quantity > 0
    result = execute_query(conn, db_type, """
        SELECT match_id, rejected_quantity, receipt_quantity, rejection_rate
        FROM main.three_way_match
        WHERE receipt_quantity > 0
        AND rejected_quantity IS NOT NULL
        AND ABS(rejection_rate - (rejected_quantity / receipt_quantity * 100)) > 0.1
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Rejection rate calculation errors: {result}")
    print("Rejection rate calculations are correct")
    conn.close()


def test_expected_amount_calculation():
    """
    Verify that expected_amount is calculated correctly.

    Formula: accepted_quantity * po_unit_price
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, accepted_quantity, po_unit_price, expected_amount
        FROM main.three_way_match
        WHERE accepted_quantity IS NOT NULL
        AND po_unit_price IS NOT NULL
        AND ABS(expected_amount - (accepted_quantity * po_unit_price)) > 0.01
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Expected amount calculation errors: {result}")
    print("Expected amount calculations are correct")
    conn.close()


def test_exception_count_calculation():
    """
    Verify that exception_count matches the number of codes in exception_reasons.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, exception_reasons, exception_count
        FROM main.three_way_match
        WHERE exception_reasons = 'NONE' AND exception_count != 0
        LIMIT 5
    """)

    require(len(result) == 0,
            f"NONE exception_reasons should have exception_count=0: {result}")

    # Check that non-NONE entries have correct count
    result = execute_query(conn, db_type, """
        SELECT
            match_id,
            exception_reasons,
            exception_count,
            LENGTH(exception_reasons) - LENGTH(REPLACE(exception_reasons, '|', '')) + 1 as calculated_count
        FROM main.three_way_match
        WHERE exception_reasons != 'NONE'
        AND exception_reasons IS NOT NULL
        AND exception_count != LENGTH(exception_reasons) - LENGTH(REPLACE(exception_reasons, '|', '')) + 1
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Exception count mismatch: {result}")
    print("Exception count calculations are correct")
    conn.close()


def test_receipt_count_calculation():
    """
    Verify that receipt_count counts distinct receipts for each PO line.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        WITH receipt_counts AS (
            SELECT
                prl.po_line_id,
                COUNT(DISTINCT por.receipt_id) as calculated_count
            FROM PROCUREMENT.PURCHASE_ORDER_RECEIPT_LINES prl
            INNER JOIN PROCUREMENT.PURCHASE_ORDER_RECEIPTS por
                ON prl.receipt_id = por.receipt_id
            GROUP BY prl.po_line_id
        )
        SELECT
            t.match_id, t.po_line_id, t.receipt_count, rc.calculated_count
        FROM main.three_way_match t
        LEFT JOIN receipt_counts rc ON t.po_line_id = rc.po_line_id
        WHERE t.receipt_count IS NOT NULL
        AND rc.calculated_count IS NOT NULL
        AND t.receipt_count != rc.calculated_count
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Receipt count mismatch: {result}")
    print("Receipt counts are calculated correctly")
    conn.close()


def test_invoice_count_calculation():
    """
    Verify that invoice_count counts distinct invoices for each PO line.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        WITH invoice_counts AS (
            SELECT
                sil.po_line_id,
                COUNT(DISTINCT si.invoice_id) as calculated_count
            FROM PROCUREMENT.SUPPLIER_INVOICE_LINES sil
            INNER JOIN PROCUREMENT.SUPPLIER_INVOICES si
                ON sil.invoice_id = si.invoice_id
            WHERE sil.po_line_id IS NOT NULL
            GROUP BY sil.po_line_id
        )
        SELECT
            t.match_id, t.po_line_id, t.invoice_count, ic.calculated_count
        FROM main.three_way_match t
        LEFT JOIN invoice_counts ic ON t.po_line_id = ic.po_line_id
        WHERE t.invoice_count IS NOT NULL
        AND ic.calculated_count IS NOT NULL
        AND t.invoice_count != ic.calculated_count
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Invoice count mismatch: {result}")
    print("Invoice counts are calculated correctly")
    conn.close()


def test_high_reject_exception():
    """
    Verify that HIGH_REJECT exception is flagged when rejection_rate > 10%.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, rejection_rate, exception_reasons
        FROM main.three_way_match
        WHERE rejection_rate > 10
        AND (
            exception_reasons IS NULL
            OR exception_reasons = ''
            OR POSITION('HIGH_REJECT' IN exception_reasons) = 0
        )
        LIMIT 5
    """)

    require(len(result) == 0,
            f"High rejection rates missing HIGH_REJECT exception: {result}")
    print("HIGH_REJECT exception flagging is correct")
    conn.close()


def test_multi_invoice_exception():
    """
    Verify that MULTI_INVOICE exception is flagged when invoice_count > 1.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, invoice_count, exception_reasons
        FROM main.three_way_match
        WHERE invoice_count > 1
        AND (
            exception_reasons IS NULL
            OR exception_reasons = ''
            OR POSITION('MULTI_INVOICE' IN exception_reasons) = 0
        )
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Multiple invoices missing MULTI_INVOICE exception: {result}")
    print("MULTI_INVOICE exception flagging is correct")
    conn.close()


def test_low_supplier_rating_exception():
    """
    Verify that LOW_SUPPLIER_RATING exception is flagged when supplier_rating < 3.0 or NULL.

    Note: APPROVED matches have exception_reasons = 'NONE', so we exclude those.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, supplier_rating, exception_reasons, overall_match_status
        FROM main.three_way_match
        WHERE (supplier_rating < 3.0 OR supplier_rating IS NULL)
        AND overall_match_status != 'APPROVED'
        AND (
            exception_reasons IS NULL
            OR exception_reasons = ''
            OR POSITION('LOW_SUPPLIER_RATING' IN exception_reasons) = 0
        )
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Low supplier ratings missing LOW_SUPPLIER_RATING exception: {result}")
    print("LOW_SUPPLIER_RATING exception flagging is correct")
    conn.close()


def test_blocked_for_critical_risk():
    """
    Verify that BLOCKED status is applied when risk_score >= 80.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, risk_score, risk_category, overall_match_status
        FROM main.three_way_match
        WHERE risk_score >= 80
        AND overall_match_status != 'BLOCKED'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"CRITICAL risk items not BLOCKED: {result}")
    print("BLOCKED status applied for CRITICAL risk items")
    conn.close()


def test_blocked_for_high_rejection():
    """
    Verify that BLOCKED status is applied when rejection_rate > 25%.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, rejection_rate, overall_match_status
        FROM main.three_way_match
        WHERE rejection_rate > 25
        AND overall_match_status != 'BLOCKED'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"High rejection rate items not BLOCKED: {result}")
    print("BLOCKED status applied for high rejection rates")
    conn.close()


def test_escalate_to_management_for_critical():
    """
    Verify that ESCALATE_TO_MANAGEMENT is recommended for CRITICAL risk items.

    Per action decision logic: if risk_category = 'CRITICAL' and not PENDING_RECEIPT
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, risk_category, overall_match_status, recommended_action
        FROM main.three_way_match
        WHERE risk_category = 'CRITICAL'
        AND overall_match_status != 'PENDING_RECEIPT'
        AND recommended_action != 'ESCALATE_TO_MANAGEMENT'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"CRITICAL risk items not recommending ESCALATE_TO_MANAGEMENT: {result}")
    print("ESCALATE_TO_MANAGEMENT recommended for CRITICAL risk")
    conn.close()


def test_risk_score_quantity_variance_component():
    """
    Verify the quantity variance component of risk score calculation.

    For records with high quantity variance (>10%), the risk score should
    include points from that component (at least 25 from quantity alone).
    """
    conn, db_type = get_connection()

    # For records with very high quantity variance (>10%), risk score must be >= 25
    result = execute_query(conn, db_type, """
        SELECT match_id, quantity_variance_pct, risk_score
        FROM main.three_way_match
        WHERE ABS(quantity_variance_pct) > 10
        AND risk_score < 25
        LIMIT 5
    """)

    require(len(result) == 0,
            f"High quantity variance records should have risk_score >= 25: {result}")
    print("Risk score quantity variance component validated")
    conn.close()


def test_risk_score_price_variance_component():
    """
    Verify the price variance component of risk score calculation.

    For records with high price variance (>5%), the risk score should
    include points from that component (at least 25 from price alone).
    """
    conn, db_type = get_connection()

    # For records with very high price variance (>5%), risk score must be >= 25
    result = execute_query(conn, db_type, """
        SELECT match_id, price_variance_pct, risk_score
        FROM main.three_way_match
        WHERE ABS(price_variance_pct) > 5
        AND risk_score < 25
        LIMIT 5
    """)

    require(len(result) == 0,
            f"High price variance records should have risk_score >= 25: {result}")
    print("Risk score price variance component validated")
    conn.close()


def test_weighted_average_price_for_multiple_invoices():
    """
    Verify that invoice_unit_price is calculated as weighted average when
    multiple invoice lines exist for the same PO line.

    Formula: SUM(line_total) / SUM(quantity)
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        WITH invoice_check AS (
            SELECT
                sil.po_line_id,
                SUM(sil.line_total) / NULLIF(SUM(sil.quantity), 0) as expected_unit_price,
                COUNT(*) as line_count
            FROM PROCUREMENT.SUPPLIER_INVOICE_LINES sil
            WHERE sil.po_line_id IS NOT NULL
            GROUP BY sil.po_line_id
            HAVING COUNT(*) > 1
        )
        SELECT
            t.match_id,
            t.invoice_unit_price,
            ic.expected_unit_price,
            ic.line_count
        FROM main.three_way_match t
        JOIN invoice_check ic ON t.po_line_id = ic.po_line_id
        WHERE ABS(t.invoice_unit_price - ic.expected_unit_price) > 0.01
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Weighted average price calculation errors for multi-line invoices: {result}")
    print("Weighted average price for multiple invoices is correct")
    conn.close()


def test_wait_for_receipt_action_precedence():
    """
    Verify that WAIT_FOR_RECEIPT action takes precedence for PENDING_RECEIPT status.

    Per action decision logic, PENDING_RECEIPT should always result in WAIT_FOR_RECEIPT,
    even if other conditions like CRITICAL risk would normally apply.
    """
    conn, db_type = get_connection()

    result = execute_query(conn, db_type, """
        SELECT match_id, overall_match_status, recommended_action
        FROM main.three_way_match
        WHERE overall_match_status = 'PENDING_RECEIPT'
        AND recommended_action != 'WAIT_FOR_RECEIPT'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"PENDING_RECEIPT should always recommend WAIT_FOR_RECEIPT: {result}")
    print("WAIT_FOR_RECEIPT action precedence is correct")
    conn.close()
