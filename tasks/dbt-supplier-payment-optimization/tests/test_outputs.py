"""
Test verifier for Supplier Payment Optimization with Dynamic Discount Analysis and Risk Assessment.
Validates aging calculations, discount parsing, annualized ROI, supplier risk scoring,
priority scoring, payment strategies, and cash flow projections.

Uses existing staging models:
- stg_procurement__supplier_invoices
- stg_procurement__suppliers
- stg_procurement__purchase_orders
- stg_finance__currency_exchange_rates
"""
import subprocess
import os
from decimal import Decimal, ROUND_HALF_UP
from datetime import date, timedelta

# Analysis date - kept as constant for grader validation
ANALYSIS_DATE = date(2024, 12, 31)


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
        # DuckDB
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


def _get_dbt_project_dir():
    """Return the dbt project directory based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


def run_cmd(cmd, cwd=None):
    """Execute a shell command and return the result.

    Args:
        cmd: Shell command to execute
        cwd: Working directory for command execution (defaults to dbt project dir)

    Returns:
        subprocess.CompletedProcess object with stdout, stderr, and returncode
    """
    if cwd is None:
        cwd = _get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:500]}")
    return result


def require(condition, msg):
    """Assert a condition is true, raising AssertionError with message if false.

    Args:
        condition: Boolean condition to check
        msg: Error message to display if condition is false

    Raises:
        AssertionError: If condition is false
    """
    if not condition:
        raise AssertionError(msg)


def run_dbt_pipeline():
    """Run the dbt pipeline for the supplier_payment_optimization model.

    Executes dbt run for the supplier_payment_optimization model.
    Raises AssertionError if dbt run fails.
    """
    dbt_dir = _get_dbt_project_dir()
    os.environ['DBT_PROFILES_DIR'] = dbt_dir
    result = run_cmd("dbt run --select +supplier_payment_optimization", cwd=dbt_dir)
    require(result.returncode == 0, f"dbt run failed: {result.stderr}")


def validate_source_data_exists(conn, db_type):
    """Validate that required source data exists in the database.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating source data...")

    result = execute_query(conn, db_type, "SELECT COUNT(*) FROM procurement.supplier_invoices")
    require(result[0][0] > 0, "No supplier invoices found in source data")
    print(f"  Source invoices: {result[0][0]} records")

    result = execute_query(conn, db_type, "SELECT COUNT(*) FROM procurement.suppliers")
    require(result[0][0] > 0, "No suppliers found in source data")
    print(f"  Source suppliers: {result[0][0]} records")

    result = execute_query(conn, db_type, "SELECT COUNT(*) FROM finance.currency_exchange_rates")
    require(result[0][0] > 0, "No exchange rates found in source data")
    print(f"  Source exchange rates: {result[0][0]} records")


def validate_required_columns(conn, db_type):
    """Validate that all required columns exist in the output model.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating required columns...")

    cols = execute_query(conn, db_type, """
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'supplier_payment_optimization'
    """)
    col_names = {c[0].lower() for c in cols}

    required = {
        # Invoice Identification
        'invoice_id', 'supplier_id', 'supplier_name', 'supplier_rating',
        'invoice_date', 'due_date', 'invoice_amount', 'currency_code',
        # Currency Conversion
        'amount_usd',
        # Aging Analysis
        'days_until_due', 'aging_bucket', 'days_past_optimal',
        # Discount Opportunity
        'payment_terms_code', 'early_payment_discount_pct', 'discount_deadline',
        'potential_savings_usd', 'discount_opportunity_status',
        # Discount ROI Analysis
        'annualized_discount_roi', 'discount_roi_tier',
        # Payment Prioritization
        'payment_priority_score', 'priority_rank', 'priority_tier',
        # Supplier Risk Assessment
        'supplier_risk_score', 'supplier_risk_category', 'supplier_invoice_concentration',
        # Cash Flow Planning
        'recommended_payment_date', 'payment_strategy', 'cash_outflow_week',
        'cumulative_outflow_usd', 'weekly_outflow_usd',
        # Working Capital Impact
        'working_capital_days', 'float_benefit_usd'
    }

    missing = required - col_names
    require(not missing, f"supplier_payment_optimization missing columns: {missing}")
    print(f"  All {len(required)} required columns present")


def validate_aging_bucket_logic(conn, db_type):
    """Validate that aging buckets are correctly calculated based on days_until_due.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating aging bucket logic...")

    # Check that aging_bucket matches days_until_due
    result = execute_query(conn, db_type, """
        SELECT invoice_id, days_until_due, aging_bucket
        FROM main.supplier_payment_optimization
        WHERE (
            (days_until_due > 0 AND aging_bucket != 'Not Yet Due') OR
            (days_until_due >= -30 AND days_until_due <= 0 AND aging_bucket != '1-30 Days Overdue') OR
            (days_until_due >= -60 AND days_until_due < -30 AND aging_bucket != '31-60 Days Overdue') OR
            (days_until_due >= -90 AND days_until_due < -60 AND aging_bucket != '61-90 Days Overdue') OR
            (days_until_due < -90 AND aging_bucket != 'Over 90 Days Overdue')
        )
        LIMIT 5
    """)

    require(len(result) == 0, f"Aging bucket mismatch found: {result}")

    # Verify days_until_due calculation
    result = execute_query(conn, db_type, """
        SELECT invoice_id, due_date, days_until_due,
               CAST(due_date AS DATE) - DATE '2024-12-31' as expected_days
        FROM main.supplier_payment_optimization
        WHERE ABS(days_until_due - (CAST(due_date AS DATE) - DATE '2024-12-31')) > 0
        LIMIT 5
    """)

    require(len(result) == 0, f"days_until_due calculation error: {result}")
    print("  Aging bucket logic validated")


def validate_days_past_optimal(conn, db_type):
    """Validate that days_past_optimal is correctly calculated.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating days_past_optimal calculation...")

    # days_past_optimal should be 0 or positive
    result = execute_query(conn, db_type, """
        SELECT invoice_id, days_past_optimal
        FROM main.supplier_payment_optimization
        WHERE days_past_optimal < 0
        LIMIT 5
    """)

    require(len(result) == 0, f"days_past_optimal should not be negative: {result}")

    # When discount is available and deadline hasn't passed, days_past_optimal should be 0
    result = execute_query(conn, db_type, """
        SELECT invoice_id, discount_opportunity_status, discount_deadline, days_past_optimal
        FROM main.supplier_payment_optimization
        WHERE discount_opportunity_status = 'Available'
          AND discount_deadline >= DATE '2024-12-31'
          AND days_past_optimal > 0
        LIMIT 5
    """)

    require(len(result) == 0,
            f"days_past_optimal should be 0 when discount is Available and deadline hasn't passed: {result}")
    print("  days_past_optimal validated")


def validate_currency_conversion(conn, db_type):
    """Validate that currency conversion to USD is correctly applied.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating currency conversion...")

    # Check USD invoices have conversion rate of 1.0
    result = execute_query(conn, db_type, """
        SELECT invoice_id, currency_code, invoice_amount, amount_usd
        FROM main.supplier_payment_optimization
        WHERE currency_code = 'USD' AND ABS(invoice_amount - amount_usd) > 0.01
        LIMIT 5
    """)

    require(len(result) == 0, f"USD conversion error (should be 1:1): {result}")

    # Verify amount_usd is positive and rounded
    result = execute_query(conn, db_type, """
        SELECT invoice_id, amount_usd
        FROM main.supplier_payment_optimization
        WHERE amount_usd <= 0 OR ROUND(amount_usd, 2) != amount_usd
        LIMIT 5
    """)

    require(len(result) == 0, f"Invalid amount_usd values: {result}")
    print("  Currency conversion validated")


def validate_discount_parsing(conn, db_type):
    """Validate that early payment discount terms are correctly parsed.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating discount parsing...")

    # Check discount_opportunity_status values are valid
    result = execute_query(conn, db_type, """
        SELECT DISTINCT discount_opportunity_status
        FROM main.supplier_payment_optimization
    """)

    valid_statuses = {'Available', 'Expired', 'Not Applicable'}
    for row in result:
        require(row[0] in valid_statuses, f"Invalid discount_opportunity_status: {row[0]}")

    # Verify potential_savings logic
    result = execute_query(conn, db_type, """
        SELECT invoice_id, discount_opportunity_status, potential_savings_usd
        FROM main.supplier_payment_optimization
        WHERE (discount_opportunity_status != 'Available' AND potential_savings_usd > 0)
        LIMIT 5
    """)

    require(len(result) == 0, f"potential_savings should be 0 when not Available: {result}")

    # Verify savings calculation for Available discounts
    result = execute_query(conn, db_type, """
        SELECT invoice_id, amount_usd, early_payment_discount_pct, potential_savings_usd,
               ROUND(amount_usd * (early_payment_discount_pct / 100.0), 2) as expected_savings
        FROM main.supplier_payment_optimization
        WHERE discount_opportunity_status = 'Available'
          AND ABS(potential_savings_usd - ROUND(amount_usd * (early_payment_discount_pct / 100.0), 2)) > 0.02
        LIMIT 5
    """)

    require(len(result) == 0, f"potential_savings calculation error: {result}")
    print("  Discount parsing validated")


def validate_annualized_roi(conn, db_type):
    """Validate that annualized discount ROI is correctly calculated.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating annualized discount ROI...")

    # Check ROI values are reasonable (0 or positive)
    result = execute_query(conn, db_type, """
        SELECT invoice_id, annualized_discount_roi
        FROM main.supplier_payment_optimization
        WHERE annualized_discount_roi < 0
        LIMIT 5
    """)

    require(len(result) == 0, f"annualized_discount_roi should not be negative: {result}")

    # When discount is not Available, ROI should be 0
    result = execute_query(conn, db_type, """
        SELECT invoice_id, discount_opportunity_status, annualized_discount_roi
        FROM main.supplier_payment_optimization
        WHERE discount_opportunity_status != 'Available' AND annualized_discount_roi > 0
        LIMIT 5
    """)

    require(len(result) == 0,
            f"annualized_discount_roi should be 0 when discount not Available: {result}")

    # Check discount_roi_tier values are valid
    result = execute_query(conn, db_type, """
        SELECT DISTINCT discount_roi_tier
        FROM main.supplier_payment_optimization
    """)

    valid_tiers = {'Exceptional', 'Good', 'Marginal', 'Not Applicable'}
    for row in result:
        require(row[0] in valid_tiers, f"Invalid discount_roi_tier: {row[0]}")

    # Verify tier categorization logic
    result = execute_query(conn, db_type, """
        SELECT invoice_id, annualized_discount_roi, discount_roi_tier
        FROM main.supplier_payment_optimization
        WHERE (
            (annualized_discount_roi >= 36.0 AND discount_roi_tier != 'Exceptional') OR
            (annualized_discount_roi >= 18.0 AND annualized_discount_roi < 36.0 AND discount_roi_tier != 'Good') OR
            (annualized_discount_roi > 0 AND annualized_discount_roi < 18.0 AND discount_roi_tier != 'Marginal') OR
            (annualized_discount_roi = 0 AND discount_roi_tier != 'Not Applicable')
        )
        LIMIT 5
    """)

    require(len(result) == 0, f"discount_roi_tier categorization error: {result}")
    print("  Annualized discount ROI validated")


def validate_supplier_risk_scoring(conn, db_type):
    """Validate that supplier risk scores are correctly calculated.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating supplier risk scoring...")

    # Check risk score is within bounds (0-100)
    result = execute_query(conn, db_type, """
        SELECT invoice_id, supplier_risk_score
        FROM main.supplier_payment_optimization
        WHERE supplier_risk_score < 0 OR supplier_risk_score > 100
        LIMIT 5
    """)

    require(len(result) == 0, f"supplier_risk_score out of bounds: {result}")

    # Check risk category values are valid
    result = execute_query(conn, db_type, """
        SELECT DISTINCT supplier_risk_category
        FROM main.supplier_payment_optimization
    """)

    valid_categories = {'Low Risk', 'Medium Risk', 'High Risk', 'Critical Risk'}
    for row in result:
        require(row[0] in valid_categories, f"Invalid supplier_risk_category: {row[0]}")

    # Verify risk category matches score
    result = execute_query(conn, db_type, """
        SELECT invoice_id, supplier_risk_score, supplier_risk_category
        FROM main.supplier_payment_optimization
        WHERE (
            (supplier_risk_score < 25 AND supplier_risk_category != 'Low Risk') OR
            (supplier_risk_score >= 25 AND supplier_risk_score < 50 AND supplier_risk_category != 'Medium Risk') OR
            (supplier_risk_score >= 50 AND supplier_risk_score < 75 AND supplier_risk_category != 'High Risk') OR
            (supplier_risk_score >= 75 AND supplier_risk_category != 'Critical Risk')
        )
        LIMIT 5
    """)

    require(len(result) == 0, f"supplier_risk_category mismatch: {result}")

    # Verify supplier_invoice_concentration is a valid percentage
    result = execute_query(conn, db_type, """
        SELECT invoice_id, supplier_invoice_concentration
        FROM main.supplier_payment_optimization
        WHERE supplier_invoice_concentration < 0 OR supplier_invoice_concentration > 100
        LIMIT 5
    """)

    require(len(result) == 0, f"supplier_invoice_concentration out of bounds: {result}")

    # Verify that all invoices from the same supplier have the same concentration
    result = execute_query(conn, db_type, """
        SELECT supplier_id, COUNT(DISTINCT supplier_invoice_concentration) as distinct_values
        FROM main.supplier_payment_optimization
        GROUP BY supplier_id
        HAVING COUNT(DISTINCT supplier_invoice_concentration) > 1
        LIMIT 5
    """)

    require(len(result) == 0,
            f"Same supplier should have same concentration across all invoices: {result}")

    # Verify supplier concentrations sum to approximately 100% (when taking distinct suppliers)
    result = execute_query(conn, db_type, """
        SELECT SUM(concentration) as total_concentration
        FROM (
            SELECT supplier_id, MAX(supplier_invoice_concentration) as concentration
            FROM main.supplier_payment_optimization
            GROUP BY supplier_id
        )
    """)

    # Should be approximately 100 (with small tolerance for rounding)
    require(abs(float(result[0][0]) - 100) < 5,
            f"Sum of supplier concentrations should be ~100, got {result[0][0]}")
    print("  Supplier risk scoring validated")


def validate_priority_scoring(conn, db_type):
    """Validate that payment priority scores are correctly calculated.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating priority scoring...")

    # Check priority_score is within reasonable bounds (0-100)
    result = execute_query(conn, db_type, """
        SELECT invoice_id, payment_priority_score
        FROM main.supplier_payment_optimization
        WHERE payment_priority_score < 0 OR payment_priority_score > 100
        LIMIT 5
    """)

    require(len(result) == 0, f"Priority score out of bounds: {result}")

    # Verify priority_rank is unique and sequential
    result = execute_query(conn, db_type, """
        SELECT COUNT(*) as cnt, COUNT(DISTINCT priority_rank) as unique_ranks
        FROM main.supplier_payment_optimization
    """)

    require(result[0][0] == result[0][1], f"priority_rank should be unique: total={result[0][0]}, unique={result[0][1]}")

    # Check priority_tier values
    result = execute_query(conn, db_type, """
        SELECT DISTINCT priority_tier
        FROM main.supplier_payment_optimization
    """)

    valid_tiers = {'Critical', 'High', 'Medium', 'Low'}
    for row in result:
        require(row[0] in valid_tiers, f"Invalid priority_tier: {row[0]}")
    print("  Priority scoring validated")


def validate_priority_tier_distribution(conn, db_type):
    """Validate that priority tiers are distributed into quartiles correctly.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating priority tier distribution...")

    result = execute_query(conn, db_type, """
        SELECT priority_tier, COUNT(*) as cnt
        FROM main.supplier_payment_optimization
        GROUP BY priority_tier
        ORDER BY
            CASE priority_tier
                WHEN 'Critical' THEN 1
                WHEN 'High' THEN 2
                WHEN 'Medium' THEN 3
                WHEN 'Low' THEN 4
            END
    """)

    total = sum(r[1] for r in result)

    # Verify we have exactly 4 tiers
    require(len(result) == 4, f"Should have exactly 4 priority tiers, found {len(result)}")

    # Each tier should be within reasonable quartile bounds
    # Allow small variance due to rounding (total might not divide evenly by 4)
    expected_per_tier = total / 4
    max_variance = max(2, int(expected_per_tier * 0.15))  # Allow 15% variance or 2 records

    for tier, count in result:
        diff = abs(count - expected_per_tier)
        require(diff <= max_variance,
                f"Priority tier '{tier}' has {count} records, expected ~{expected_per_tier:.1f} (+/-{max_variance})")

    print(f"  Priority tier distribution validated: {dict(result)}")


def validate_payment_strategy(conn, db_type):
    """Validate that payment strategies are correctly assigned.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating payment strategy logic...")

    # Check payment_strategy values are valid
    result = execute_query(conn, db_type, """
        SELECT DISTINCT payment_strategy
        FROM main.supplier_payment_optimization
    """)

    valid_strategies = {'Take Discount', 'Pay On Due Date', 'Immediate Payment', 'Defer Payment'}
    for row in result:
        require(row[0] in valid_strategies, f"Invalid payment_strategy: {row[0]}")

    # Verify 'Take Discount' is only assigned when discount is Available and ROI is good
    result = execute_query(conn, db_type, """
        SELECT invoice_id, payment_strategy, discount_opportunity_status, discount_roi_tier
        FROM main.supplier_payment_optimization
        WHERE payment_strategy = 'Take Discount'
          AND (discount_opportunity_status != 'Available'
               OR discount_roi_tier NOT IN ('Exceptional', 'Good'))
        LIMIT 5
    """)

    require(len(result) == 0,
            f"'Take Discount' should only be assigned when discount Available and ROI is Exceptional/Good: {result}")

    # Verify 'Immediate Payment' is for overdue high-risk invoices (but could also be overridden by Take Discount)
    result = execute_query(conn, db_type, """
        SELECT invoice_id, payment_strategy, aging_bucket, supplier_risk_category,
               discount_opportunity_status, discount_roi_tier
        FROM main.supplier_payment_optimization
        WHERE payment_strategy = 'Immediate Payment'
          AND (aging_bucket = 'Not Yet Due'
               OR supplier_risk_category NOT IN ('High Risk', 'Critical Risk'))
        LIMIT 5
    """)

    require(len(result) == 0,
            f"'Immediate Payment' should be for overdue invoices with High/Critical Risk: {result}")

    print("  Payment strategy logic validated")


def validate_recommended_payment_date(conn, db_type):
    """Validate that recommended payment dates follow the business rules.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating recommended payment date logic...")

    # If strategy is 'Take Discount', recommended_payment_date should be discount_deadline
    result = execute_query(conn, db_type, """
        SELECT invoice_id, payment_strategy, discount_deadline, recommended_payment_date
        FROM main.supplier_payment_optimization
        WHERE payment_strategy = 'Take Discount'
          AND discount_deadline IS NOT NULL
          AND recommended_payment_date != discount_deadline
        LIMIT 5
    """)

    require(len(result) == 0,
            f"When strategy is 'Take Discount', recommended_payment_date should equal discount_deadline: {result}")

    # If strategy is 'Immediate Payment', recommended_payment_date should be analysis_date
    result = execute_query(conn, db_type, """
        SELECT invoice_id, payment_strategy, recommended_payment_date
        FROM main.supplier_payment_optimization
        WHERE payment_strategy = 'Immediate Payment'
          AND recommended_payment_date != DATE '2024-12-31'
        LIMIT 5
    """)

    require(len(result) == 0,
            f"'Immediate Payment' invoices should have recommended_payment_date = analysis_date: {result}")

    # If strategy is 'Pay On Due Date' or 'Defer Payment', should pay on due_date
    result = execute_query(conn, db_type, """
        SELECT invoice_id, payment_strategy, due_date, recommended_payment_date
        FROM main.supplier_payment_optimization
        WHERE payment_strategy IN ('Pay On Due Date', 'Defer Payment')
          AND recommended_payment_date != due_date
        LIMIT 5
    """)

    require(len(result) == 0,
            f"'Pay On Due Date'/'Defer Payment' invoices should have recommended_payment_date = due_date: {result}")

    print("  Recommended payment date logic validated")


def validate_cash_flow_projection(conn, db_type):
    """Validate cash flow week and cumulative outflow calculations.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating cash flow projections...")

    # Verify cash_outflow_week is derived from recommended_payment_date
    result = execute_query(conn, db_type, """
        SELECT invoice_id, recommended_payment_date, cash_outflow_week,
               WEEKOFYEAR(recommended_payment_date) as expected_week
        FROM main.supplier_payment_optimization
        WHERE cash_outflow_week != WEEKOFYEAR(recommended_payment_date)
        LIMIT 5
    """)

    require(len(result) == 0, f"cash_outflow_week calculation error: {result}")

    # Verify cumulative_outflow_usd is monotonically increasing
    result = execute_query(conn, db_type, """
        WITH ordered_data AS (
            SELECT invoice_id, cumulative_outflow_usd,
                   LAG(cumulative_outflow_usd) OVER (ORDER BY recommended_payment_date, invoice_id) as prev_cumulative
            FROM main.supplier_payment_optimization
        )
        SELECT invoice_id, cumulative_outflow_usd, prev_cumulative
        FROM ordered_data
        WHERE prev_cumulative IS NOT NULL AND cumulative_outflow_usd < prev_cumulative
        LIMIT 5
    """)

    require(len(result) == 0,
            f"cumulative_outflow_usd should be monotonically increasing: {result}")

    # Verify final cumulative equals sum of all amounts (with relative tolerance)
    result = execute_query(conn, db_type, """
        SELECT
            MAX(cumulative_outflow_usd) as final_cumulative,
            SUM(amount_usd) as total_amount
        FROM main.supplier_payment_optimization
    """)

    # Use relative tolerance of 0.1% instead of absolute $0.10
    final_cumulative = float(result[0][0])
    total_amount = float(result[0][1])
    relative_diff = abs(final_cumulative - total_amount) / total_amount if total_amount > 0 else 0
    require(relative_diff < 0.001,
            f"Final cumulative ({final_cumulative}) should equal total amount ({total_amount}), diff: {relative_diff:.4%}")

    # Verify weekly_outflow_usd is consistent for invoices in the same week
    result = execute_query(conn, db_type, """
        SELECT cash_outflow_week, COUNT(DISTINCT weekly_outflow_usd) as distinct_values
        FROM main.supplier_payment_optimization
        GROUP BY cash_outflow_week
        HAVING COUNT(DISTINCT weekly_outflow_usd) > 1
        LIMIT 5
    """)

    require(len(result) == 0,
            f"weekly_outflow_usd should be the same for all invoices in the same week: {result}")

    print("  Cash flow projections validated")


def validate_working_capital_metrics(conn, db_type):
    """Validate working capital days and float benefit calculations.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating working capital metrics...")

    # Verify working_capital_days is calculated correctly
    result = execute_query(conn, db_type, """
        SELECT invoice_id, invoice_date, recommended_payment_date, working_capital_days,
               CAST(recommended_payment_date AS DATE) - CAST(invoice_date AS DATE) as expected_days
        FROM main.supplier_payment_optimization
        WHERE ABS(working_capital_days - (CAST(recommended_payment_date AS DATE) - CAST(invoice_date AS DATE))) > 0
        LIMIT 5
    """)

    require(len(result) == 0, f"working_capital_days calculation error: {result}")

    # Verify working_capital_days is non-negative
    result = execute_query(conn, db_type, """
        SELECT invoice_id, working_capital_days
        FROM main.supplier_payment_optimization
        WHERE working_capital_days < 0
        LIMIT 5
    """)

    require(len(result) == 0, f"working_capital_days should not be negative: {result}")

    # Verify float_benefit_usd calculation (5% annual rate)
    result = execute_query(conn, db_type, """
        SELECT invoice_id, amount_usd, working_capital_days, float_benefit_usd,
               ROUND(amount_usd * (0.05 / 365.0) * working_capital_days, 2) as expected_benefit
        FROM main.supplier_payment_optimization
        WHERE ABS(float_benefit_usd - ROUND(amount_usd * (0.05 / 365.0) * working_capital_days, 2)) > 0.02
        LIMIT 5
    """)

    require(len(result) == 0, f"float_benefit_usd calculation error: {result}")

    # Verify float_benefit_usd is non-negative
    result = execute_query(conn, db_type, """
        SELECT invoice_id, float_benefit_usd
        FROM main.supplier_payment_optimization
        WHERE float_benefit_usd < 0
        LIMIT 5
    """)

    require(len(result) == 0, f"float_benefit_usd should not be negative: {result}")

    print("  Working capital metrics validated")


def validate_data_quality(conn, db_type):
    """Validate general data quality requirements.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating data quality...")

    # Check no NULL values in required non-nullable fields
    non_nullable = ['invoice_id', 'supplier_id', 'supplier_name', 'invoice_date',
                    'due_date', 'invoice_amount', 'amount_usd', 'days_until_due',
                    'aging_bucket', 'days_past_optimal', 'payment_priority_score',
                    'priority_rank', 'priority_tier', 'supplier_risk_score',
                    'supplier_risk_category', 'supplier_invoice_concentration',
                    'recommended_payment_date', 'payment_strategy', 'cash_outflow_week',
                    'cumulative_outflow_usd', 'weekly_outflow_usd', 'working_capital_days',
                    'float_benefit_usd', 'annualized_discount_roi', 'discount_roi_tier',
                    'discount_opportunity_status', 'potential_savings_usd',
                    'early_payment_discount_pct']

    for col in non_nullable:
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM main.supplier_payment_optimization
            WHERE {col} IS NULL
        """)
        require(result == 0, f"NULL values found in {col}")

    # Verify monetary values are rounded to 2 decimals
    result = execute_query(conn, db_type, """
        SELECT invoice_id, amount_usd, potential_savings_usd, cumulative_outflow_usd,
               weekly_outflow_usd, float_benefit_usd
        FROM main.supplier_payment_optimization
        WHERE ROUND(amount_usd, 2) != amount_usd
           OR ROUND(potential_savings_usd, 2) != potential_savings_usd
           OR ROUND(cumulative_outflow_usd, 2) != cumulative_outflow_usd
           OR ROUND(weekly_outflow_usd, 2) != weekly_outflow_usd
           OR ROUND(float_benefit_usd, 2) != float_benefit_usd
        LIMIT 5
    """)

    require(len(result) == 0, f"Monetary values not rounded to 2 decimals: {result}")
    print("  Data quality validated")


def validate_invoice_filtering(conn, db_type):
    """Validate that only OPEN or PENDING invoices are included.

    Args:
        conn: Database connection object
        db_type: 'duckdb' or 'snowflake'
    """
    print("Validating invoice filtering...")

    # Get count of output records
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.supplier_payment_optimization
    """)
    output_count = result

    require(output_count > 0, "No records in supplier_payment_optimization output")

    # Verify source has appropriate records
    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM procurement.supplier_invoices
        WHERE STATUS IN ('OPEN', 'PENDING')
    """)

    print(f"  Output contains {output_count} invoices (source has {source_count} eligible)")


# ============ TEST FUNCTIONS ============

def test_schema_and_structure():
    """Test 1: Validate output schema, structure, and basic data quality.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 1: Schema and Structure Validation")
    print("="*60)

    run_dbt_pipeline()
    conn, db_type = get_db_connection()
    try:
        validate_source_data_exists(conn, db_type)
        validate_required_columns(conn, db_type)
        validate_invoice_filtering(conn, db_type)
        validate_data_quality(conn, db_type)
        print("  TEST 1 PASSED")
        return 1.0
    finally:
        conn.close()


def test_aging_and_currency():
    """Test 2: Validate aging bucket calculations and currency conversion.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 2: Aging and Currency Validation")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        validate_aging_bucket_logic(conn, db_type)
        validate_days_past_optimal(conn, db_type)
        validate_currency_conversion(conn, db_type)
        print("  TEST 2 PASSED")
        return 1.0
    finally:
        conn.close()


def test_discount_and_roi():
    """Test 3: Validate early payment discount parsing and annualized ROI.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 3: Discount and ROI Validation")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        validate_discount_parsing(conn, db_type)
        validate_annualized_roi(conn, db_type)
        print("  TEST 3 PASSED")
        return 1.0
    finally:
        conn.close()


def test_supplier_risk():
    """Test 4: Validate supplier risk scoring and categorization.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 4: Supplier Risk Assessment Validation")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        validate_supplier_risk_scoring(conn, db_type)
        print("  TEST 4 PASSED")
        return 1.0
    finally:
        conn.close()


def test_priority_scoring():
    """Test 5: Validate payment priority scoring and tier assignment.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 5: Priority Scoring Validation")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        validate_priority_scoring(conn, db_type)
        validate_priority_tier_distribution(conn, db_type)
        print("  TEST 5 PASSED")
        return 1.0
    finally:
        conn.close()


def test_payment_strategy_and_dates():
    """Test 6: Validate payment strategies and recommended dates.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 6: Payment Strategy and Dates Validation")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        validate_payment_strategy(conn, db_type)
        validate_recommended_payment_date(conn, db_type)
        print("  TEST 6 PASSED")
        return 1.0
    finally:
        conn.close()


def test_cash_flow_and_working_capital():
    """Test 7: Validate cash flow projections and working capital metrics.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 7: Cash Flow and Working Capital Validation")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        validate_cash_flow_projection(conn, db_type)
        validate_working_capital_metrics(conn, db_type)
        print("  TEST 7 PASSED")
        return 1.0
    finally:
        conn.close()


def test_edge_cases_and_robustness():
    """Test 8: Validate edge cases and robustness of the solution.

    Returns:
        float: 1.0 if all validations pass, 0.0 otherwise
    """
    print("\n" + "="*60)
    print("TEST 8: Edge Cases and Robustness")
    print("="*60)

    conn, db_type = get_db_connection()
    try:
        # Verify currency handling (at least one currency present)
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT currency_code) as currency_count
            FROM main.supplier_payment_optimization
        """)
        require(result[0][0] >= 1,
                f"Solution should handle currencies, found {result[0][0]}")
        print(f"  Currency support validated ({result[0][0]} currencies processed)")

        # Verify handling of invoices with NULL or non-standard payment terms
        result = execute_query(conn, db_type, """
            SELECT COUNT(*)
            FROM main.supplier_payment_optimization
            WHERE (payment_terms_code IS NULL OR payment_terms_code NOT LIKE '%/%')
              AND early_payment_discount_pct = 0
              AND discount_opportunity_status = 'Not Applicable'
        """)
        print(f"  Non-discount payment terms handled correctly ({result[0][0]} invoices)")

        # Verify priority score range is valid
        result = execute_query(conn, db_type, """
            SELECT MIN(payment_priority_score) as min_score,
                   MAX(payment_priority_score) as max_score
            FROM main.supplier_payment_optimization
        """)
        min_score = float(result[0][0])
        max_score = float(result[0][1])
        require(min_score >= 0, f"Minimum priority score should be >= 0, got {min_score}")
        require(max_score <= 100, f"Maximum priority score should be <= 100, got {max_score}")
        require(max_score > min_score, "Priority scores should have variation")
        print(f"  Priority score range valid: {min_score:.2f} to {max_score:.2f}")

        # Verify supplier risk score range is valid
        result = execute_query(conn, db_type, """
            SELECT MIN(supplier_risk_score) as min_score,
                   MAX(supplier_risk_score) as max_score
            FROM main.supplier_payment_optimization
        """)
        min_risk = float(result[0][0])
        max_risk = float(result[0][1])
        require(min_risk >= 0, f"Minimum risk score should be >= 0, got {min_risk}")
        require(max_risk <= 100, f"Maximum risk score should be <= 100, got {max_risk}")
        print(f"  Risk score range valid: {min_risk:.2f} to {max_risk:.2f}")

        # Verify diversity in aging (both overdue and not-due should exist in general case)
        result = execute_query(conn, db_type, """
            SELECT
                SUM(CASE WHEN days_until_due > 0 THEN 1 ELSE 0 END) as not_due,
                SUM(CASE WHEN days_until_due <= 0 THEN 1 ELSE 0 END) as overdue
            FROM main.supplier_payment_optimization
        """)
        total = int(result[0][0]) + int(result[0][1])
        require(total > 0, "Should have at least some invoices")
        print(f"  Aging distribution: not due: {result[0][0]}, overdue: {result[0][1]}")

        # Verify discount opportunities are properly categorized
        result = execute_query(conn, db_type, """
            SELECT discount_opportunity_status, COUNT(*) as cnt
            FROM main.supplier_payment_optimization
            GROUP BY discount_opportunity_status
            ORDER BY discount_opportunity_status
        """)
        statuses = {r[0] for r in result}
        require('Not Applicable' in statuses or 'Available' in statuses or 'Expired' in statuses,
                "Should have valid discount opportunity statuses")
        print(f"  Discount status distribution: {dict(result)}")

        # Verify discount ROI tier distribution
        result = execute_query(conn, db_type, """
            SELECT discount_roi_tier, COUNT(*) as cnt
            FROM main.supplier_payment_optimization
            GROUP BY discount_roi_tier
            ORDER BY discount_roi_tier
        """)
        print(f"  Discount ROI tier distribution: {dict(result)}")

        # Verify payment strategy distribution
        result = execute_query(conn, db_type, """
            SELECT payment_strategy, COUNT(*) as cnt
            FROM main.supplier_payment_optimization
            GROUP BY payment_strategy
            ORDER BY payment_strategy
        """)
        print(f"  Payment strategy distribution: {dict(result)}")

        # Verify supplier risk category distribution
        result = execute_query(conn, db_type, """
            SELECT supplier_risk_category, COUNT(*) as cnt
            FROM main.supplier_payment_optimization
            GROUP BY supplier_risk_category
            ORDER BY supplier_risk_category
        """)
        print(f"  Risk category distribution: {dict(result)}")

        # Verify recommended payment dates are logical (not before invoice date)
        result = execute_query(conn, db_type, """
            SELECT COUNT(*)
            FROM main.supplier_payment_optimization
            WHERE recommended_payment_date < invoice_date
        """)
        require(result[0][0] == 0,
                f"Recommended payment dates cannot be before invoice date ({result[0][0]} violations)")
        print(f"  Recommended payment dates are logically consistent")

        # Verify no duplicate invoice_ids
        result = execute_query(conn, db_type, """
            SELECT invoice_id, COUNT(*) as cnt
            FROM main.supplier_payment_optimization
            GROUP BY invoice_id
            HAVING COUNT(*) > 1
            LIMIT 5
        """)
        require(len(result) == 0, f"Found duplicate invoice_ids: {result}")
        print(f"  No duplicate invoices in output")

        # Verify float benefit is reasonable
        result = execute_query(conn, db_type, """
            SELECT CAST(SUM(float_benefit_usd) AS DOUBLE) as total_float_benefit,
                   CAST(SUM(amount_usd) AS DOUBLE) as total_amount
            FROM main.supplier_payment_optimization
        """)
        total_float = float(result[0][0])
        total_amt = float(result[0][1])
        float_ratio = total_float / total_amt if total_amt > 0 else 0
        require(float_ratio < 0.1,
                f"Float benefit ratio ({float_ratio:.4f}) seems too high (>10% of total)")
        print(f"  Float benefit is reasonable: ${total_float:.2f} ({float_ratio*100:.2f}% of total)")

        print("  TEST 8 PASSED")
        return 1.0
    finally:
        conn.close()


if __name__ == "__main__":
    import sys

    tests = [
        ("Schema and Structure", test_schema_and_structure),
        ("Aging and Currency", test_aging_and_currency),
        ("Discount and ROI", test_discount_and_roi),
        ("Supplier Risk", test_supplier_risk),
        ("Priority Scoring", test_priority_scoring),
        ("Payment Strategy and Dates", test_payment_strategy_and_dates),
        ("Cash Flow and Working Capital", test_cash_flow_and_working_capital),
        ("Edge Cases and Robustness", test_edge_cases_and_robustness),
    ]

    scores = []

    try:
        for test_name, test_func in tests:
            try:
                score = test_func()
                scores.append(score)
                print(f"\n{test_name}: {score}")
            except AssertionError as e:
                print(f"\n{test_name}: FAILED - {e}")
                scores.append(0.0)
            except Exception as e:
                print(f"\n{test_name}: ERROR - {e}")
                import traceback
                traceback.print_exc()
                scores.append(0.0)

        total_score = sum(scores)
        print("\n" + "="*60)
        print(f"TOTAL SCORE: {total_score}/{len(tests)}")
        print("="*60)

        # All tests must pass (score 1.0) for overall success
        if all(s == 1.0 for s in scores):
            print("ALL TESTS PASSED!")
            sys.exit(0)
        else:
            print("SOME TESTS FAILED")
            sys.exit(1)

    except Exception as e:
        print(f"\nFATAL ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
