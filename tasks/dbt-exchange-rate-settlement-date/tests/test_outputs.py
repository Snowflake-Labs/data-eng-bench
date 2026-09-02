import subprocess
import os
import pytest

SCHEMA_NAME = "main"
_DB_TYPE = os.environ.get('DB_TYPE', 'duckdb').lower()
ORDER_PAYMENTS_TABLE = "ORDERS.ORDER_PAYMENTS" if _DB_TYPE == 'snowflake' else "main.order_payments"

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




def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    """
    Execute a shell command and return the result.

    Args:
        cmd: The shell command to execute.
        cwd: Working directory for command execution.

    Returns:
        subprocess.CompletedProcess with stdout, stderr, and returncode.
    """
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """
    Run dbt deps and dbt run for the fact_revenue model.

    Raises:
        AssertionError: If dbt deps or dbt run fails.
    """
    deps = run_cmd("dbt deps")
    assert deps.returncode == 0, f"dbt deps failed: {deps.stderr}"
    res = run_cmd("dbt run --select fact_revenue")
    assert res.returncode == 0, f"dbt run failed: {res.stderr}"


@pytest.fixture(scope="module")
def dbt_run():
    """
    Pytest fixture that runs the dbt pipeline once per test module.

    Returns:
        bool: True if pipeline ran successfully.
    """
    run_dbt_pipeline()
    return True


def fetch_fact_revenue_rows():
    """
    Fetch all rows from fact_revenue with key columns for validation.

    Returns:
        List of tuples containing (order_date, settlement_date, currency_code,
        source_system, total_revenue, net_revenue, total_revenue_usd,
        net_revenue_usd, fx_rate).
    """
    conn, db_type = get_db_connection()
    try:
        return execute_query(conn, db_type, f"""
            SELECT
                order_date,
                settlement_date,
                currency_code,
                source_system,
                total_revenue,
                net_revenue,
                total_revenue_usd,
                net_revenue_usd,
                fx_rate
            FROM {SCHEMA_NAME}.fact_revenue
            ORDER BY order_date, settlement_date, currency_code, source_system
        """)
    finally:
        conn.close()


def fetch_non_usd_sample(limit=5):
    """
    Fetch a sample of non-USD rows for FX rate validation.

    Args:
        limit: Maximum number of rows to return.

    Returns:
        List of tuples containing (order_date, settlement_date, currency_code,
        source_system, total_revenue_usd, net_revenue_usd, fx_rate).
    """
    conn, db_type = get_db_connection()
    try:
        return execute_query(conn, db_type, f"""
            SELECT
                order_date,
                settlement_date,
                currency_code,
                source_system,
                total_revenue_usd,
                net_revenue_usd,
                fx_rate
            FROM {SCHEMA_NAME}.fact_revenue
            WHERE currency_code != 'USD'
            ORDER BY order_date, settlement_date, currency_code, source_system
            LIMIT {limit}
        """)
    finally:
        conn.close()


def fetch_fact_revenue_keys():
    """
    Fetch the unique grain keys from fact_revenue.

    Returns:
        List of tuples containing (order_date, settlement_date, currency_code,
        source_system) for each unique combination.
    """
    conn, db_type = get_db_connection()
    try:
        return execute_query(conn, db_type, f"""
            SELECT order_date, settlement_date, currency_code, source_system
            FROM {SCHEMA_NAME}.fact_revenue
            GROUP BY 1,2,3,4
        """)
    finally:
        conn.close()


def fetch_expected_keys():
    """
    Calculate expected grain keys by joining fct_sales with order_payments.

    Uses settlement_date from order_payments (max processed_at), falling back
    to order_date when no payment exists.

    Returns:
        List of tuples containing expected (order_date, settlement_date,
        currency_code, source_system) combinations.
    """
    conn, db_type = get_db_connection()
    try:
        return execute_query(conn, db_type, f"""
            WITH payments AS (
                SELECT order_id, CAST(MAX(processed_at) AS DATE) AS settlement_date
                FROM {ORDER_PAYMENTS_TABLE}
                GROUP BY order_id
            )
            SELECT
                s.order_date,
                COALESCE(p.settlement_date, s.order_date) AS settlement_date,
                s.currency_code,
                s.source_system
            FROM main.fct_sales s
            LEFT JOIN payments p ON s.order_id = p.order_id
            WHERE s.order_date IS NOT NULL
            GROUP BY 1,2,3,4
        """)
    finally:
        conn.close()


def fetch_expected_revenue_totals():
    """
    Calculate expected USD revenue totals using settlement date FX rates.

    Joins fct_sales with order_payments to determine settlement date, then
    looks up FX rates from dim_exchange_rates using that settlement date.

    Returns:
        List of tuples containing (order_date, settlement_date, currency_code,
        source_system, expected_net_usd, expected_total_usd).
    """
    conn, db_type = get_db_connection()
    try:
        return execute_query(conn, db_type, f"""
            WITH payments AS (
                SELECT order_id, CAST(MAX(processed_at) AS DATE) AS settlement_date
                FROM {ORDER_PAYMENTS_TABLE}
                GROUP BY order_id
            ),
            sales AS (
                SELECT
                    s.order_id,
                    s.order_date,
                    s.currency_code,
                    s.source_system,
                    s.line_total,
                    s.extended_price,
                    s.discount_amount,
                    COALESCE(p.settlement_date, s.order_date) AS settlement_date
                FROM main.fct_sales s
                LEFT JOIN payments p ON s.order_id = p.order_id
                WHERE s.order_date IS NOT NULL
            ),
            sales_fx AS (
                SELECT
                    s.*,
                    CASE
                        WHEN s.currency_code = 'USD' THEN 1.0
                        ELSE COALESCE(r.rate, 1.0)
                    END AS fx_rate
                FROM sales s
                LEFT JOIN main.dim_exchange_rates r
                    ON s.currency_code = r.from_currency
                    AND r.to_currency = 'USD'
                    AND r.rate_date = s.settlement_date
            )
            SELECT
                order_date,
                settlement_date,
                currency_code,
                source_system,
                ROUND(SUM((extended_price - discount_amount) * fx_rate), 2) AS expected_net_usd,
                ROUND(SUM(line_total * fx_rate), 2) AS expected_total_usd
            FROM sales_fx
            GROUP BY 1,2,3,4
        """)
    finally:
        conn.close()


def count_groups_where_order_date_fx_differs():
    """
    Count grain groups where settlement-date FX produces different results than order-date FX.

    This identifies cases where using the correct settlement date actually
    makes a difference in the calculated USD amounts.

    Returns:
        int: Number of groups with differing FX calculations.
    """
    conn, db_type = get_db_connection()
    try:
        row = execute_query(conn, db_type, f"""
            WITH payments AS (
                SELECT order_id, CAST(MAX(processed_at) AS DATE) AS settlement_date
                FROM {ORDER_PAYMENTS_TABLE}
                GROUP BY order_id
            ),
            sales AS (
                SELECT
                    s.order_id,
                    s.order_date,
                    s.currency_code,
                    s.source_system,
                    s.line_total,
                    COALESCE(p.settlement_date, s.order_date) AS settlement_date
                FROM main.fct_sales s
                LEFT JOIN payments p ON s.order_id = p.order_id
                WHERE s.order_date IS NOT NULL
            ),
            settlement_fx AS (
                SELECT
                    s.order_date,
                    s.settlement_date,
                    s.currency_code,
                    s.source_system,
                    SUM(s.line_total * CASE
                        WHEN s.currency_code = 'USD' THEN 1.0
                        ELSE COALESCE(r.rate, 1.0)
                    END) AS total_usd
                FROM sales s
                LEFT JOIN main.dim_exchange_rates r
                    ON s.currency_code = r.from_currency
                    AND r.to_currency = 'USD'
                    AND r.rate_date = s.settlement_date
                GROUP BY 1,2,3,4
            ),
            order_fx AS (
                SELECT
                    s.order_date,
                    s.settlement_date,
                    s.currency_code,
                    s.source_system,
                    SUM(s.line_total * CASE
                        WHEN s.currency_code = 'USD' THEN 1.0
                        ELSE COALESCE(r.rate, 1.0)
                    END) AS total_usd
                FROM sales s
                LEFT JOIN main.dim_exchange_rates r
                    ON s.currency_code = r.from_currency
                    AND r.to_currency = 'USD'
                    AND r.rate_date = s.order_date
                GROUP BY 1,2,3,4
            )
            SELECT COUNT(*)
            FROM settlement_fx s
            JOIN order_fx o
              ON s.order_date = o.order_date
             AND s.settlement_date = o.settlement_date
             AND s.currency_code = o.currency_code
             AND s.source_system = o.source_system
            WHERE s.total_usd IS NOT NULL
              AND o.total_usd IS NOT NULL
              AND ABS(s.total_usd - o.total_usd) > 0.01
        """)
        return row[0][0]
    finally:
        conn.close()


def fetch_no_payment_orders(limit=20):
    """
    Fetch order groups that have no corresponding payment records.

    These orders should fall back to using order_date as settlement_date.

    Args:
        limit: Maximum number of groups to return.

    Returns:
        List of tuples containing (order_date, currency_code, source_system)
        for orders without payments.
    """
    conn, db_type = get_db_connection()
    try:
        return execute_query(conn, db_type, f"""
            SELECT s.order_date, s.currency_code, s.source_system
            FROM main.fct_sales s
            LEFT JOIN {ORDER_PAYMENTS_TABLE} p ON s.order_id = p.order_id
            WHERE p.order_id IS NULL
              AND s.order_date IS NOT NULL
            GROUP BY 1,2,3
            LIMIT {limit}
        """)
    finally:
        conn.close()


def get_fx_rate(rate_date, currency_code):
    """
    Look up the FX rate for a specific date and currency from dim_exchange_rates.

    Args:
        rate_date: The date to look up the rate for.
        currency_code: The source currency code (converts to USD).

    Returns:
        float or None: The exchange rate, or None if not found.
    """
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT rate
            FROM main.dim_exchange_rates
            WHERE rate_date = %s
              AND from_currency = %s
              AND to_currency = 'USD'
            LIMIT 1
        """ if db_type == 'snowflake' else """
            SELECT rate
            FROM main.dim_exchange_rates
            WHERE rate_date = ?
              AND from_currency = ?
              AND to_currency = 'USD'
            LIMIT 1
        """, [rate_date, currency_code])
        return rows[0][0] if rows else None
    finally:
        conn.close()


def fetch_fx_rate_mismatches_for_settlement_date():
    """
    Count rows where fact_revenue.fx_rate doesn't match the dim rate for settlement_date.

    Returns:
        int: Number of rows with mismatched FX rates.
    """
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, f"""
            SELECT COUNT(*)
            FROM {SCHEMA_NAME}.fact_revenue fr
            JOIN main.dim_exchange_rates r
              ON fr.currency_code = r.from_currency
             AND r.to_currency = 'USD'
             AND r.rate_date = fr.settlement_date
            WHERE fr.currency_code != 'USD'
              AND ABS(fr.fx_rate - r.rate) > 0.0001
        """)
        return rows[0][0]
    finally:
        conn.close()


def count_groups_where_settlement_rate_differs_from_order_rate():
    """
    Count grain groups where the FX rate on settlement_date differs from order_date.

    This validates that there are meaningful test cases where using the
    correct date actually produces different exchange rates.

    Returns:
        int: Number of groups with different rates on settlement vs order date.
    """
    conn, db_type = get_db_connection()
    try:
        row = execute_query(conn, db_type, f"""
            WITH payments AS (
                SELECT order_id, CAST(MAX(processed_at) AS DATE) AS settlement_date
                FROM {ORDER_PAYMENTS_TABLE}
                GROUP BY order_id
            ),
            sales AS (
                SELECT
                    s.order_id,
                    s.order_date,
                    s.currency_code,
                    s.source_system,
                    COALESCE(p.settlement_date, s.order_date) AS settlement_date
                FROM main.fct_sales s
                LEFT JOIN payments p ON s.order_id = p.order_id
                WHERE s.order_date IS NOT NULL
            ),
            rates AS (
                SELECT
                    s.order_date,
                    s.settlement_date,
                    s.currency_code,
                    s.source_system,
                    r_set.rate AS settlement_rate,
                    r_ord.rate AS order_rate
                FROM sales s
                LEFT JOIN main.dim_exchange_rates r_set
                    ON s.currency_code = r_set.from_currency
                    AND r_set.to_currency = 'USD'
                    AND r_set.rate_date = s.settlement_date
                LEFT JOIN main.dim_exchange_rates r_ord
                    ON s.currency_code = r_ord.from_currency
                    AND r_ord.to_currency = 'USD'
                    AND r_ord.rate_date = s.order_date
            )
            SELECT COUNT(*) FROM (
                SELECT order_date, settlement_date, currency_code, source_system
                FROM rates
                WHERE settlement_rate IS NOT NULL
                  AND order_rate IS NOT NULL
                  AND settlement_rate != order_rate
                GROUP BY 1,2,3,4
            )
        """)
        return row[0][0]
    finally:
        conn.close()


def count_rows_where_fx_rate_matches_order_rate_when_different():
    """
    Count rows that incorrectly use order_date rate instead of settlement_date rate.

    When settlement_rate and order_rate differ, the fact_revenue.fx_rate should
    match the settlement_rate, not the order_rate. This function counts violations.

    Returns:
        int: Number of rows incorrectly using order_date rate.
    """
    conn, db_type = get_db_connection()
    try:
        row = execute_query(conn, db_type, f"""
            WITH order_rates AS (
                SELECT
                    fr.order_date,
                    fr.settlement_date,
                    fr.currency_code,
                    fr.source_system,
                    fr.fx_rate,
                    r_set.rate AS settlement_rate,
                    r_ord.rate AS order_rate
                FROM {SCHEMA_NAME}.fact_revenue fr
                LEFT JOIN main.dim_exchange_rates r_set
                    ON fr.currency_code = r_set.from_currency
                    AND r_set.to_currency = 'USD'
                    AND r_set.rate_date = fr.settlement_date
                LEFT JOIN main.dim_exchange_rates r_ord
                    ON fr.currency_code = r_ord.from_currency
                    AND r_ord.to_currency = 'USD'
                    AND r_ord.rate_date = fr.order_date
                WHERE fr.currency_code != 'USD'
                  AND r_set.rate IS NOT NULL
                  AND r_ord.rate IS NOT NULL
                  AND ABS(r_set.rate - r_ord.rate) > 0.01
            )
            SELECT COUNT(*)
            FROM order_rates
            WHERE ABS(fx_rate - settlement_rate) > 0.01
               OR ABS(fx_rate - order_rate) <= 0.01
        """)
        return row[0][0]
    finally:
        conn.close()


def compute_expected(order_date, settlement_date, currency_code, source_system, use_order_date_rate=False):
    """
    Compute expected USD revenue totals for a specific grain using either settlement or order date FX.

    Args:
        order_date: The order date to filter on.
        settlement_date: The settlement date to filter on.
        currency_code: The currency code to filter on.
        source_system: The source system to filter on.
        use_order_date_rate: If True, use order_date for FX lookup instead of settlement_date.

    Returns:
        Tuple of (expected_total_usd, expected_net_usd) as floats.
    """
    conn, db_type = get_db_connection()
    try:
        rate_date_expr = "s.order_date" if use_order_date_rate else "s.settlement_date"
        placeholder = "%s" if db_type == 'snowflake' else "?"
        query = f"""
            WITH payments AS (
                SELECT order_id, CAST(MAX(processed_at) AS DATE) AS settlement_date
                FROM {ORDER_PAYMENTS_TABLE}
                GROUP BY order_id
            ),
            sales AS (
                SELECT
                    s.order_id,
                    s.order_date,
                    s.currency_code,
                    s.source_system,
                    s.line_total,
                    s.extended_price,
                    s.discount_amount,
                    COALESCE(p.settlement_date, s.order_date) AS settlement_date
                FROM main.fct_sales s
                LEFT JOIN payments p ON s.order_id = p.order_id
            )
            SELECT
                SUM(s.line_total * CASE
                    WHEN s.currency_code = 'USD' THEN 1.0
                    ELSE COALESCE(r.rate, 1.0)
                END) AS total_usd,
                SUM((s.extended_price - s.discount_amount) * CASE
                    WHEN s.currency_code = 'USD' THEN 1.0
                    ELSE COALESCE(r.rate, 1.0)
                END) AS net_usd
            FROM sales s
            LEFT JOIN main.dim_exchange_rates r
                ON s.currency_code = r.from_currency
                AND r.to_currency = 'USD'
                AND r.rate_date = {rate_date_expr}
            WHERE s.order_date = {placeholder}
              AND s.settlement_date = {placeholder}
              AND s.currency_code = {placeholder}
              AND s.source_system = {placeholder}
        """
        rows = execute_query(conn, db_type, query, [order_date, settlement_date, currency_code, source_system])
        row = rows[0] if rows else (None, None)
        return float(row[0] or 0.0), float(row[1] or 0.0)
    finally:
        conn.close()


class TestStructure:
    """Tests for fact_revenue table structure and basic integrity."""

    def test_columns_exist(self, dbt_run):
        """Verify all required columns exist in fact_revenue table."""
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                SELECT column_name
                FROM information_schema.columns
                WHERE lower(table_schema) = '{SCHEMA_NAME}'
                  AND lower(table_name) = 'fact_revenue'
            """)
            col_names = {c[0].lower() for c in cols}
            required = {
                "settlement_date",
                "fx_rate",
                "net_revenue_usd",
                "total_revenue_usd",
            }
            missing = required - col_names
            assert not missing, f"Missing columns in fact_revenue: {missing}"
        finally:
            conn.close()

    def test_settlement_date_not_null(self, dbt_run):
        """Verify settlement_date is populated for all rows."""
        rows = fetch_fact_revenue_rows()
        assert rows, "fact_revenue has no rows"
        for row in rows:
            assert row[1] is not None, f"NULL settlement_date in row: {row}"

    def test_some_rows_have_different_settlement_date(self, dbt_run):
        """Verify at least some rows have settlement_date different from order_date."""
        rows = fetch_fact_revenue_rows()
        diff = [r for r in rows if r[0] != r[1]]
        assert len(diff) > 0, "Expected at least one row with settlement_date != order_date"

    def test_grain_matches_expected_keys(self, dbt_run):
        """Verify fact_revenue grain matches expected keys from source data."""
        actual_keys = set(fetch_fact_revenue_keys())
        expected_keys = set(fetch_expected_keys())
        missing = expected_keys - actual_keys
        extra = actual_keys - expected_keys
        assert not missing, f"Missing keys in fact_revenue: {list(missing)[:5]}"
        assert not extra, f"Unexpected keys in fact_revenue: {list(extra)[:5]}"


class TestFxRates:
    """Tests for FX rate correctness and handling."""

    def test_usd_identity(self, dbt_run):
        """Verify USD transactions have matching local and USD amounts (1:1 rate)."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT total_revenue, total_revenue_usd, net_revenue, net_revenue_usd
                FROM {SCHEMA_NAME}.fact_revenue
                WHERE currency_code = 'USD'
                  AND total_revenue IS NOT NULL
                  AND total_revenue_usd IS NOT NULL
                  AND net_revenue IS NOT NULL
                  AND net_revenue_usd IS NOT NULL
                LIMIT 50
            """)
            assert rows, "No USD rows found in fact_revenue with non-null USD metrics"
            for total_rev, total_usd, net_rev, net_usd in rows:
                assert abs(float(total_rev) - float(total_usd)) < 0.02
                assert abs(float(net_rev) - float(net_usd)) < 0.02
        finally:
            conn.close()

    def test_fx_rate_matches_dim(self, dbt_run):
        """Verify fx_rate matches dim_exchange_rates for settlement_date."""
        samples = fetch_non_usd_sample(limit=5)
        assert samples, "No non-USD rows found for fx rate validation"
        for order_date, settlement_date, currency_code, source_system, total_usd, net_usd, fx_rate in samples:
            expected_rate = get_fx_rate(settlement_date, currency_code)
            if expected_rate is None:
                assert abs(float(fx_rate) - 1.0) < 0.0001
            else:
                assert abs(float(fx_rate) - float(expected_rate)) < 0.0001

    def test_fx_rate_not_null(self, dbt_run):
        """Verify no rows have NULL fx_rate."""
        conn, db_type = get_db_connection()
        try:
            row = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA_NAME}.fact_revenue
                WHERE fx_rate IS NULL
            """)
            assert row[0][0] == 0, f"Found {row[0][0]} rows with NULL fx_rate"
        finally:
            conn.close()

    def test_fx_rate_fallback_for_missing_currencies(self, dbt_run):
        """Verify currencies not in dim_exchange_rates fall back to 1.0 rate."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT currency_code, fx_rate
                FROM {SCHEMA_NAME}.fact_revenue
                WHERE currency_code NOT IN ('USD', 'EUR', 'GBP', 'CAD', 'AUD', 'JPY')
                LIMIT 10
            """)
            if rows:
                for currency_code, fx_rate in rows:
                    assert abs(float(fx_rate) - 1.0) < 0.0001, \
                        f"Expected fallback fx_rate=1.0 for {currency_code}, got {fx_rate}"
        finally:
            conn.close()

    def test_usd_fields_rounded(self, dbt_run):
        """Verify USD amounts are rounded to 2 decimal places."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT total_revenue_usd, net_revenue_usd
                FROM {SCHEMA_NAME}.fact_revenue
                WHERE total_revenue_usd IS NOT NULL
                  AND net_revenue_usd IS NOT NULL
                LIMIT 100
            """)
            for total_usd, net_usd in rows:
                assert float(total_usd) == round(float(total_usd), 2)
                assert float(net_usd) == round(float(net_usd), 2)
        finally:
            conn.close()

    def test_non_usd_rates_not_identity_when_rate_exists(self, dbt_run):
        """Verify non-USD currencies use actual FX rates when available (not 1.0)."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT fr.currency_code, fr.fx_rate
                FROM {SCHEMA_NAME}.fact_revenue fr
                JOIN main.dim_exchange_rates r
                  ON fr.currency_code = r.from_currency
                 AND r.to_currency = 'USD'
                 AND r.rate_date = fr.settlement_date
                WHERE fr.currency_code != 'USD'
                LIMIT 50
            """)
            assert rows, "No non-USD rows with matching FX rates"
            for currency_code, fx_rate in rows:
                assert abs(float(fx_rate) - 1.0) > 0.0001, \
                    f"Non-USD currency {currency_code} unexpectedly used identity rate"
        finally:
            conn.close()

    def test_fx_rate_matches_dim_for_all_rows(self, dbt_run):
        """Verify all non-USD rows have fx_rate matching dim_exchange_rates for settlement_date."""
        mismatches = fetch_fx_rate_mismatches_for_settlement_date()
        assert mismatches == 0, f"Found {mismatches} rows with fx_rate != dim rate"

    def test_usd_fx_rate_is_identity(self, dbt_run):
        """Verify all USD rows have fx_rate = 1.0."""
        conn, db_type = get_db_connection()
        try:
            row = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA_NAME}.fact_revenue
                WHERE currency_code = 'USD' AND ABS(fx_rate - 1.0) > 0.0001
            """)
            assert row[0][0] == 0, f"Found {row[0][0]} USD rows with fx_rate != 1.0"
        finally:
            conn.close()


class TestFxConversion:
    """Tests for correct USD conversion using settlement date FX rates."""

    def test_usd_totals_match_expected(self, dbt_run):
        """Verify USD totals match expected values calculated with settlement date rates."""
        samples = fetch_non_usd_sample(limit=3)
        for order_date, settlement_date, currency_code, source_system, total_usd, net_usd, fx_rate in samples:
            expected_total, expected_net = compute_expected(
                order_date, settlement_date, currency_code, source_system, use_order_date_rate=False
            )
            assert abs(float(total_usd) - round(expected_total, 2)) < 0.05
            assert abs(float(net_usd) - round(expected_net, 2)) < 0.05

    def test_uses_settlement_date_rates(self, dbt_run):
        """Verify conversion uses settlement date rates, not order date rates."""
        samples = fetch_non_usd_sample(limit=3)
        for order_date, settlement_date, currency_code, source_system, total_usd, net_usd, fx_rate in samples:
            if order_date == settlement_date:
                continue
            expected_settlement, _ = compute_expected(
                order_date, settlement_date, currency_code, source_system, use_order_date_rate=False
            )
            expected_order_date, _ = compute_expected(
                order_date, settlement_date, currency_code, source_system, use_order_date_rate=True
            )
            diff_settlement = abs(float(total_usd) - round(expected_settlement, 2))
            diff_order = abs(float(total_usd) - round(expected_order_date, 2))
            assert diff_settlement <= diff_order + 0.01, (
                f"Expected settlement-date FX to be closer. settlement diff={diff_settlement}, order diff={diff_order}"
            )

    def test_all_rows_match_expected_settlement_fx(self, dbt_run):
        """Verify all rows match expected USD amounts using settlement date FX."""
        conn, db_type = get_db_connection()
        try:
            row = execute_query(conn, db_type, f"""
                WITH payments AS (
                    SELECT order_id, CAST(MAX(processed_at) AS DATE) AS settlement_date
                    FROM {ORDER_PAYMENTS_TABLE}
                    GROUP BY order_id
                ),
                sales AS (
                    SELECT
                        s.order_id,
                        s.order_date,
                        s.currency_code,
                        s.source_system,
                        s.line_total,
                        s.extended_price,
                        s.discount_amount,
                        COALESCE(p.settlement_date, s.order_date) AS settlement_date
                    FROM main.fct_sales s
                    LEFT JOIN payments p ON s.order_id = p.order_id
                    WHERE s.order_date IS NOT NULL
                ),
                sales_fx AS (
                    SELECT
                        s.*,
                        CASE
                            WHEN s.currency_code = 'USD' THEN 1.0
                            ELSE COALESCE(r.rate, 1.0)
                        END AS fx_rate
                    FROM sales s
                    LEFT JOIN main.dim_exchange_rates r
                        ON s.currency_code = r.from_currency
                        AND r.to_currency = 'USD'
                        AND r.rate_date = s.settlement_date
                ),
                expected_totals AS (
                    SELECT
                        order_date,
                        settlement_date,
                        currency_code,
                        source_system,
                        ROUND(SUM((extended_price - discount_amount) * fx_rate), 2) AS expected_net_usd,
                        ROUND(SUM(line_total * fx_rate), 2) AS expected_total_usd
                    FROM sales_fx
                    GROUP BY 1,2,3,4
                ),
                actual AS (
                    SELECT
                        order_date,
                        settlement_date,
                        currency_code,
                        source_system,
                        net_revenue_usd,
                        total_revenue_usd
                    FROM {SCHEMA_NAME}.fact_revenue
                    WHERE order_date IS NOT NULL
                )
                SELECT COUNT(*) FROM (
                    SELECT
                        a.order_date,
                        a.settlement_date,
                        a.currency_code,
                        a.source_system,
                        a.net_revenue_usd,
                        a.total_revenue_usd,
                        e.expected_net_usd,
                        e.expected_total_usd
                    FROM actual a
                    JOIN expected_totals e
                      ON a.order_date = e.order_date
                     AND a.settlement_date = e.settlement_date
                     AND a.currency_code = e.currency_code
                     AND a.source_system = e.source_system
                    WHERE ABS(a.net_revenue_usd - e.expected_net_usd) >= 0.20
                       OR ABS(a.total_revenue_usd - e.expected_total_usd) >= 0.20
                ) mismatches
            """)
            assert row[0][0] == 0, f"Found {row[0][0]} rows with USD mismatches >= 0.20"
        finally:
            conn.close()

    def test_settlement_fx_differs_from_order_fx_for_some_groups(self, dbt_run):
        """Verify data contains cases where settlement and order date FX produce different results."""
        diff_count = count_groups_where_order_date_fx_differs()
        assert diff_count >= 5, "Expected at least 5 groups where settlement-date FX differs from order-date FX"

    def test_fx_rate_uses_settlement_date_when_rates_differ(self, dbt_run):
        """Verify fx_rate uses settlement date lookup when rates differ between dates."""
        diff_groups = count_groups_where_settlement_rate_differs_from_order_rate()
        assert diff_groups >= 5, "Expected at least 5 groups where settlement and order rates differ"

    def test_fx_rate_not_equal_order_rate_when_rates_differ(self, dbt_run):
        """Verify fx_rate is NOT the order date rate when settlement and order rates differ."""
        mismatches = count_rows_where_fx_rate_matches_order_rate_when_different()
        assert mismatches == 0, f"Found {mismatches} rows using order-date rate when rates differ"

    def test_usd_metrics_follow_fx_rate(self, dbt_run):
        """Verify USD metrics are calculated correctly from local amounts and fx_rate."""
        conn, db_type = get_db_connection()
        try:
            row = execute_query(conn, db_type, f"""
                SELECT COUNT(*) FROM {SCHEMA_NAME}.fact_revenue
                WHERE order_date IS NOT NULL
                  AND (ABS(net_revenue_usd - ROUND(net_revenue * fx_rate, 2)) > 0.02
                       OR ABS(total_revenue_usd - ROUND(total_revenue * fx_rate, 2)) > 0.02)
            """)
            assert row[0][0] == 0, f"Found {row[0][0]} rows where USD metrics do not match fx_rate"
        finally:
            conn.close()


class TestSettlementDateFallback:
    """Tests for settlement date fallback behavior when no payment exists."""

    def test_no_payment_orders_use_order_date(self, dbt_run):
        """Verify orders without payments fall back to using order_date as settlement_date."""
        samples = fetch_no_payment_orders(limit=10)
        if not samples:
            return
        conn, db_type = get_db_connection()
        try:
            placeholder = "%s" if db_type == 'snowflake' else "?"
            for order_date, currency_code, source_system in samples:
                # Build NULL-safe WHERE clauses and params list
                params = [order_date]
                currency_clause = "currency_code IS NULL" if currency_code is None else f"currency_code = {placeholder}"
                if currency_code is not None:
                    params.append(currency_code)
                source_clause = "source_system IS NULL" if source_system is None else f"source_system = {placeholder}"
                if source_system is not None:
                    params.append(source_system)
                row = execute_query(conn, db_type, f"""
                    SELECT COUNT(*)
                    FROM {SCHEMA_NAME}.fact_revenue
                    WHERE order_date = {placeholder}
                      AND settlement_date = order_date
                      AND {currency_clause}
                      AND {source_clause}
                """, params)
                assert row[0][0] > 0, (
                    f"Expected settlement_date=order_date for no-payment order group "
                    f"{order_date}, {currency_code}, {source_system}"
                )
        finally:
            conn.close()
