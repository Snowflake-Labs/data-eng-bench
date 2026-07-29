"""
Tests for DQ macro enforcement in fct_order_line_detail.
"""
import subprocess
import os
from pathlib import Path
import pytest

MODEL_NAME = "fct_order_line_detail"

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


def get_model_schema():
    """Return the schema name based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return 'main'
    return 'main'


MODEL_SCHEMA = get_model_schema()


def get_dbt_project_dir():
    """Return the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_transforms')


# ============ CROSS-DATABASE SQL HELPERS ============

def get_regexp_extract(db_type, column, pattern, group=1):
    """Return database-specific regex extract function"""
    if db_type == 'duckdb':
        return f"regexp_extract({column}, '{pattern}', {group})"
    else:
        # Snowflake uses REGEXP_SUBSTR with different syntax
        # For pattern '([^>]+)$' we need '[^>]+$'
        sf_pattern = pattern.replace('(', '').replace(')', '').replace('$', '') + '$'
        return f"REGEXP_SUBSTR({column}, '{sf_pattern}')"


def get_dayofweek(db_type, column):
    """Return database-specific day of week function (0=Sunday, 6=Saturday)"""
    if db_type == 'duckdb':
        return f"dayofweek({column})"
    else:
        # Snowflake DAYOFWEEK returns 0=Monday by default, we need to adjust
        # EXTRACT(DOW FROM date) returns 0=Sunday in Snowflake
        # TRY_TO_TIMESTAMP_NTZ handles VARCHAR date columns; explicit cast
        # avoids intermittent "EXTRACT does not support VARCHAR" compile errors
        return f"DAYOFWEEK(TRY_TO_TIMESTAMP_NTZ(CAST({column} AS VARCHAR)))"


def get_quantile_cont(db_type, column, percentile):
    """Return database-specific percentile function for aggregate use"""
    if db_type == 'duckdb':
        return f"quantile_cont({column}, {percentile})"
    else:
        return f"PERCENTILE_CONT({percentile}) WITHIN GROUP (ORDER BY {column})"


def get_regexp_matches(db_type, column, pattern):
    """Return database-specific regex match function"""
    if db_type == 'duckdb':
        return f"regexp_matches({column}, '{pattern}')"
    else:
        return f"REGEXP_LIKE({column}, '{pattern}')"


def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt():
    deps = run_cmd("dbt deps")
    if deps.returncode != 0:
        print(f"Warning: dbt deps failed: {deps.returncode}")
    res = run_cmd("dbt run --select fct_order_line_detail")
    assert res.returncode == 0, f"dbt run failed: {res.stderr}"


@pytest.fixture(scope="module")
def dbt_run():
    run_dbt()
    return True


class TestDQMacroEnforcement:
    def test_columns_present(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            cols = execute_query(conn, db_type, f"""
                select column_name from information_schema.columns
                where lower(table_schema) = lower('{MODEL_SCHEMA}')
                  and lower(table_name) = '{MODEL_NAME}'
            """)
            names = {c[0].lower() for c in cols}
            required = {
                "line_profit",
                "product_category_leaf",
                "line_total_corrected",
                "net_unit_price",
                "unit_price_net_corrected",
                "dq_is_valid",
                "dq_missing_required",
                "dq_format_corrected",
                "dq_duplicate_suspected",
                "dq_late_arriving",
                "dq_revenue_flag",
                "dq_quantity_flag",
                "dq_duplicate_flag",
                "dq_shipped_vs_ordered_valid",
                "dq_return_vs_shipped_valid",
                "dq_status_qty_valid",
                "dq_unit_price_iqr_flag",
                "dq_order_total_match",
                "dq_pii_flag",
                "dq_line_total_nonnegative",
                "dq_discount_rate_flag",
                "dq_margin_flag",
                "dq_line_dates_valid",
                "dq_category_missing",
            }
            missing = required - names
            assert not missing, f"Missing columns: {missing}"
        finally:
            conn.close()

    def test_row_count_matches_order_lines(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            diff = execute_query(conn, db_type, f"""
                select
                    (select count(*) from {MODEL_SCHEMA}.stg_orders__order_lines)
                    - (select count(*) from {MODEL_SCHEMA}.{MODEL_NAME}) as diff
            """)[0][0]
            assert diff == 0, f"Row count mismatch: {diff}"
        finally:
            conn.close()

    def test_macro_updates(self, dbt_run):
        dbt_dir = get_dbt_project_dir()
        add_flags = Path(f"{dbt_dir}/macros/data_quality/add_dq_flags.sql").read_text()
        dq_checks = Path(f"{dbt_dir}/macros/data_quality/dq_checks.sql").read_text()

        def macro_block(text, name):
            lower = text.lower()
            start = lower.find(f"{{% macro {name}")
            assert start != -1, f"Missing macro: {name}"
            end = lower.find("{% endmacro %}", start)
            assert end != -1, f"Unclosed macro: {name}"
            return lower[start:end]

        add_flags_block = macro_block(add_flags, "add_dq_flags")
        assert "trim(cast" in add_flags_block, "add_dq_flags must trim empty strings"

        pii_block = macro_block(dq_checks, "dq_flag_potential_pii")
        # Check for conditional logic - either regexp_matches (duckdb) or regexp_like (snowflake)
        has_conditional = "target.type" in pii_block or "regexp_matches" in pii_block or "regexp_like" in pii_block
        assert has_conditional, "dq_flag_potential_pii must use conditional regex logic"

        iqr_block = macro_block(dq_checks, "dq_flag_iqr_outlier")
        # Check for conditional logic - either quantile_cont (duckdb) or percentile_cont (snowflake)
        has_conditional = "target.type" in iqr_block or "quantile_cont" in iqr_block or "percentile_cont" in iqr_block
        assert has_conditional, "dq_flag_iqr_outlier must use conditional percentile logic"

    def test_line_total_recomputed(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with expected as (
                    select
                        ol.order_line_id,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount) as calc_line_total
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                actual as (
                    select order_line_id, line_total
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where abs(e.calc_line_total - a.line_total) > 0.0001
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} line_total mismatches"
        finally:
            conn.close()

    def test_line_profit_recomputed(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with expected as (
                    select
                        ol.order_line_id,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                            - ol.quantity_ordered * coalesce(pv.cost_price, 0) as exp_line_profit
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv
                        on ol.variant_id = pv.variant_id
                ),
                actual as (
                    select order_line_id, line_profit
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_line_profit is distinct from a.line_profit
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} line_profit mismatches"
        finally:
            conn.close()

    def test_net_unit_price_recomputed(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with expected as (
                    select
                        ol.order_line_id,
                        round((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                              / nullif(ol.quantity_ordered, 0), 2) as exp_net_unit_price
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                actual as (
                    select order_line_id, net_unit_price
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where abs(e.exp_net_unit_price - a.net_unit_price) > 0.0001
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} net_unit_price mismatches"
        finally:
            conn.close()

    def test_unit_price_net_corrected_flag(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.unit_price,
                        round((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                              / nullif(ol.quantity_ordered, 0), 2) as net_unit_price
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                expected as (
                    select
                        order_line_id,
                        case when abs(net_unit_price - unit_price) > 0.01 then true else false end as exp_flag
                    from base
                ),
                actual as (
                    select order_line_id, unit_price_net_corrected
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_flag != a.unit_price_net_corrected
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} unit_price_net_corrected mismatches"
        finally:
            conn.close()

    def test_required_field_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            regexp_extract_expr = get_regexp_extract(db_type, 'pc.category_path', '([^>]+)$', 1)
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        o.order_id,
                        o.order_number,
                        coalesce(nullif(trim(pv.sku), ''), nullif(trim(ol.sku), '')) as sku,
                        coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), '')) as product_name,
                        case
                            when pc.category_path is not null and trim(pc.category_path) != ''
                                then trim({regexp_extract_expr})
                            when pc.category_name is not null and trim(pc.category_name) != ''
                                then trim(pc.category_name)
                            else coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), ''))
                        end as product_category_leaf,
                        ol.quantity_ordered,
                        ol.unit_price,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount) as line_total,
                        round((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                              / nullif(ol.quantity_ordered, 0), 2) as net_unit_price
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv on ol.variant_id = pv.variant_id
                    left join {MODEL_SCHEMA}.stg_product__products p on pv.product_id = p.product_id
                    left join {MODEL_SCHEMA}.stg_product__product_categories pc on p.primary_category_id = pc.category_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when order_line_id is null
                              or trim(cast(order_line_id as varchar)) = ''
                              or order_id is null
                              or trim(cast(order_id as varchar)) = ''
                              or order_number is null
                              or trim(cast(order_number as varchar)) = ''
                              or sku is null
                              or trim(cast(sku as varchar)) = ''
                              or product_name is null
                              or trim(cast(product_name as varchar)) = ''
                              or product_category_leaf is null
                              or trim(cast(product_category_leaf as varchar)) = ''
                              or quantity_ordered is null
                              or unit_price is null
                              or line_total is null
                              or net_unit_price is null
                            then true
                            else false
                        end as exp_missing
                    from base
                ),
                actual as (
                    select order_line_id, dq_missing_required
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_missing != a.dq_missing_required
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} required-field flag mismatches"
        finally:
            conn.close()

    def test_product_category_leaf(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            regexp_extract_expr = get_regexp_extract(db_type, 'category_path', '([^>]+)$', 1)
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), '')) as product_name,
                        pc.category_path,
                        pc.category_name
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv on ol.variant_id = pv.variant_id
                    left join {MODEL_SCHEMA}.stg_product__products p on pv.product_id = p.product_id
                    left join {MODEL_SCHEMA}.stg_product__product_categories pc on p.primary_category_id = pc.category_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when category_path is not null and trim(category_path) != ''
                                then trim({regexp_extract_expr})
                            when category_name is not null and trim(category_name) != ''
                                then trim(category_name)
                            else product_name
                        end as exp_leaf
                    from base
                ),
                actual as (
                    select order_line_id, product_category_leaf
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(trim(e.exp_leaf), '') != coalesce(trim(a.product_category_leaf), '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} product_category_leaf mismatches"
        finally:
            conn.close()

    def test_format_corrected_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        case
                            when abs((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount) - ol.line_total) > 0.01
                            then true
                            else false
                        end as line_total_corrected,
                        case
                            when abs(
                                round((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                                      / nullif(ol.quantity_ordered, 0), 2) - ol.unit_price
                            ) > 0.01 then true
                            else false
                        end as unit_price_net_corrected,
                        case
                            when nullif(trim(pv.sku), '') is null and nullif(trim(ol.sku), '') is not null then true
                            else false
                        end as sku_fallback,
                        case
                            when nullif(trim(p.product_name), '') is null and nullif(trim(ol.product_name), '') is not null then true
                            else false
                        end as product_name_fallback
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv on ol.variant_id = pv.variant_id
                    left join {MODEL_SCHEMA}.stg_product__products p on pv.product_id = p.product_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when line_total_corrected or unit_price_net_corrected or sku_fallback or product_name_fallback then true
                            else false
                        end as exp_corrected
                    from base
                ),
                actual as (
                    select order_line_id, dq_format_corrected
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_corrected != a.dq_format_corrected
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} format correction mismatches"
        finally:
            conn.close()

    def test_revenue_anomaly_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            dayofweek_expr = get_dayofweek(db_type, 'order_ts')
            # For DuckDB dayofweek returns 0=Sunday, 6=Saturday
            # For Snowflake DAYOFWEEK returns 0=Sunday, 6=Saturday (default)
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        case
                            when ol.status in ('CREDIT','RETURNED')
                            then abs(ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                            else (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                        end as amount,
                        o.ordered_at as order_ts
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when amount < 0 then 'NEGATIVE_AMOUNT'
                            when amount = 0 then 'ZERO_AMOUNT'
                            when amount > 10000 then 'HIGH_AMOUNT'
                            when amount = round(amount, 0)
                                 and amount > 100
                                 and mod(cast(amount as integer), 100) = 0 then 'ROUND_NUMBER_SUSPECT'
                            when {dayofweek_expr} in (0, 6)
                                 and amount > 5000 then 'WEEKEND_HIGH_AMOUNT'
                            else null
                        end as exp_flag
                    from base
                ),
                actual as (
                    select order_line_id, dq_revenue_flag
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_revenue_flag, '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} revenue flag mismatches"
        finally:
            conn.close()

    def test_quantity_anomaly_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        case
                            when ol.status in ('CREDIT','RETURNED')
                            then abs(ol.quantity_ordered)
                            else ol.quantity_ordered
                        end as qty
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when qty is null then 'NULL_QUANTITY'
                            when qty < 0 then 'NEGATIVE_QUANTITY'
                            when qty = 0 then 'ZERO_QUANTITY'
                            when qty > 10000 then 'BULK_ORDER'
                            when qty != round(qty, 0) then 'FRACTIONAL_QUANTITY'
                            else null
                        end as exp_flag
                    from base
                ),
                actual as (
                    select order_line_id, dq_quantity_flag
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_quantity_flag, '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} quantity flag mismatches"
        finally:
            conn.close()

    def test_duplicate_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        o.order_id,
                        ol.product_id
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when count(*) over (partition by order_id, product_id) > 1
                            then 'POTENTIAL_DUPLICATE'
                            else null
                        end as exp_flag
                    from base
                ),
                actual as (
                    select order_line_id, dq_duplicate_flag, dq_duplicate_suspected
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_duplicate_flag, '')
                   or (case when e.exp_flag is null then false else true end) != a.dq_duplicate_suspected
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} duplicate flag mismatches"
        finally:
            conn.close()

    def test_shipped_vs_ordered_valid(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.quantity_shipped as shipped_qty,
                        ol.quantity_ordered as ordered_qty
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when shipped_qty is null or ordered_qty is null then true
                            when shipped_qty > ordered_qty * 1.05 then false
                            else true
                        end as exp_valid
                    from base
                ),
                actual as (
                    select order_line_id, dq_shipped_vs_ordered_valid
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_valid != a.dq_shipped_vs_ordered_valid
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} shipped vs ordered mismatches"
        finally:
            conn.close()

    def test_return_vs_shipped_valid(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.status,
                        ol.quantity_returned as returned_qty,
                        ol.quantity_shipped as shipped_qty
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when status = 'RETURNED' and (returned_qty is null or shipped_qty is null) then true
                            when status = 'RETURNED' and returned_qty > shipped_qty then false
                            when status = 'RETURNED' then true
                            else true
                        end as exp_valid
                    from base
                ),
                actual as (
                    select order_line_id, dq_return_vs_shipped_valid
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_valid != a.dq_return_vs_shipped_valid
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} return vs shipped mismatches"
        finally:
            conn.close()

    def test_status_qty_valid(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.status,
                        ol.quantity_shipped,
                        ol.quantity_returned,
                        ol.quantity_ordered,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount) as line_total
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when status = 'PENDING' then (coalesce(quantity_shipped, 0) = 0 and coalesce(quantity_returned, 0) = 0)
                            when status = 'SHIPPED' then quantity_shipped > 0
                            when status = 'RETURNED' then quantity_returned > 0
                            when status = 'CREDIT' then quantity_ordered < 0 and line_total < 0
                            else true
                        end as exp_valid
                    from base
                ),
                actual as (
                    select order_line_id, dq_status_qty_valid
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_valid != a.dq_status_qty_valid
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} status/qty mismatches"
        finally:
            conn.close()

    def test_unit_price_iqr_flag(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            quantile_25 = get_quantile_cont(db_type, 'net_unit_price', 0.25)
            quantile_75 = get_quantile_cont(db_type, 'net_unit_price', 0.75)
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.product_id,
                        ol.status,
                        round((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                              / nullif(ol.quantity_ordered, 0), 2) as net_unit_price
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                stats as (
                    select
                        product_id,
                        {quantile_25} as p25,
                        {quantile_75} as p75
                    from base
                    where status not in ('CREDIT','RETURNED')
                    group by product_id
                ),
                expected as (
                    select
                        b.order_line_id,
                        case
                            when b.status in ('CREDIT','RETURNED') then null
                            when b.net_unit_price < (s.p25 - 1.5 * (s.p75 - s.p25)) then 'LOW_OUTLIER'
                            when b.net_unit_price > (s.p75 + 1.5 * (s.p75 - s.p25)) then 'HIGH_OUTLIER'
                            else null
                        end as exp_flag
                    from base b
                    left join stats s on b.product_id = s.product_id
                ),
                actual as (
                    select order_line_id, dq_unit_price_iqr_flag
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_unit_price_iqr_flag, '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} unit price IQR mismatches"
        finally:
            conn.close()

    def test_order_total_match(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        o.order_id,
                        o.grand_total,
                        sum(case when ol.status = 'CREDIT'
                                 then 0
                                 else (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                            end) over (partition by o.order_id) as sum_lines
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when abs(grand_total - sum_lines) > 0.01 then false
                            else true
                        end as exp_match
                    from base
                ),
                actual as (
                    select order_line_id, dq_order_total_match
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_match != a.dq_order_total_match
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} order total mismatches"
        finally:
            conn.close()

    def test_pii_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            email_regex = get_regexp_matches(db_type, 'text_val', '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\\\.[a-zA-Z]{2,}')
            phone_regex = get_regexp_matches(db_type, 'text_val', '\\\\b\\\\d{3}[-.]?\\\\d{3}[-.]?\\\\d{4}\\\\b')
            ssn_regex = get_regexp_matches(db_type, 'text_val', '\\\\b\\\\d{3}-\\\\d{2}-\\\\d{4}\\\\b')
            cc_regex = get_regexp_matches(db_type, 'text_val', '\\\\b\\\\d{4}[- ]?\\\\d{4}[- ]?\\\\d{4}[- ]?\\\\d{4}\\\\b')
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        coalesce(o.notes, o.analyst_notes) as text_val
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when {email_regex} then 'CONTAINS_EMAIL'
                            when {phone_regex} then 'CONTAINS_PHONE'
                            when {ssn_regex} then 'CONTAINS_SSN'
                            when {cc_regex} then 'CONTAINS_CC'
                            else null
                        end as exp_flag
                    from base
                ),
                actual as (
                    select order_line_id, dq_pii_flag
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_pii_flag, '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} PII flag mismatches"
        finally:
            conn.close()

    def test_late_arriving_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.updated_at as line_updated_at,
                        o.ordered_at as order_ordered_at,
                        ol.status as line_status
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when line_status in ('CREDIT','RETURNED') then false
                            when line_updated_at is null or order_ordered_at is null then false
                            when line_updated_at > order_ordered_at + interval '2 days' then true
                            else false
                        end as exp_late
                    from base
                ),
                actual as (
                    select order_line_id, dq_late_arriving
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_late != a.dq_late_arriving
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} late-arriving mismatches"
        finally:
            conn.close()

    def test_line_total_nonnegative(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount) as line_total,
                        ol.status as line_status
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when line_status = 'CREDIT' then true
                            when line_total is null then true
                            when line_total < 0 then false
                            else true
                        end as exp_ok
                    from base
                ),
                actual as (
                    select order_line_id, dq_line_total_nonnegative
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_ok != a.dq_line_total_nonnegative
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} line total range mismatches"
        finally:
            conn.close()

    def test_discount_rate_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.status,
                        ol.discount_amount,
                        ol.unit_price,
                        ol.quantity_ordered
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                ),
                rates as (
                    select
                        order_line_id,
                        status,
                        discount_amount / nullif(unit_price * quantity_ordered, 0) as discount_rate
                    from base
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when status in ('CREDIT','RETURNED') then null
                            when discount_rate is null then null
                            when discount_rate < 0 then 'NEGATIVE_DISCOUNT'
                            when discount_rate > 1 then 'DISCOUNT_EXCEEDS_PRICE'
                            when discount_rate > 0.70 then 'HIGH_DISCOUNT'
                            else null
                        end as exp_flag
                    from rates
                ),
                actual as (
                    select order_line_id, dq_discount_rate_flag
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_discount_rate_flag, '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} discount rate flag mismatches"
        finally:
            conn.close()

    def test_margin_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        ol.status,
                        ol.quantity_ordered,
                        ol.unit_price,
                        ol.discount_amount,
                        ol.tax_amount,
                        pv.cost_price
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv
                        on ol.variant_id = pv.variant_id
                ),
                calc as (
                    select
                        order_line_id,
                        status,
                        (quantity_ordered * unit_price - discount_amount + tax_amount) as line_total,
                        (quantity_ordered * unit_price - discount_amount + tax_amount)
                            - quantity_ordered * coalesce(cost_price, 0) as line_profit
                    from base
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when status in ('CREDIT','RETURNED') then null
                            when line_total = 0 then 'ZERO_REVENUE'
                            when line_profit < 0 then 'NEGATIVE_MARGIN'
                            when line_profit / nullif(line_total, 0) > 0.80 then 'EXCESS_MARGIN'
                            else null
                        end as exp_flag
                    from calc
                ),
                actual as (
                    select order_line_id, dq_margin_flag
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where coalesce(e.exp_flag, '') != coalesce(a.dq_margin_flag, '')
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} margin flag mismatches"
        finally:
            conn.close()

    def test_line_dates_valid(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        o.ordered_at as order_ordered_at,
                        ol.created_at as line_created_at,
                        ol.updated_at as line_updated_at
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when order_ordered_at is not null
                              and line_created_at is not null
                              and order_ordered_at > line_created_at then false
                            when line_created_at is not null
                              and line_updated_at is not null
                              and line_created_at > line_updated_at then false
                            else true
                        end as exp_valid
                    from base
                ),
                actual as (
                    select order_line_id, dq_line_dates_valid
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_valid != a.dq_line_dates_valid
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} line date mismatches"
        finally:
            conn.close()

    def test_category_missing_flags(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        p.primary_category_id,
                        pc.category_id,
                        pc.category_name
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv
                        on ol.variant_id = pv.variant_id
                    left join {MODEL_SCHEMA}.stg_product__products p
                        on pv.product_id = p.product_id
                    left join {MODEL_SCHEMA}.stg_product__product_categories pc
                        on p.primary_category_id = pc.category_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when primary_category_id is null then true
                            when category_id is null then true
                            when category_name is null or trim(category_name) = '' then true
                            else false
                        end as exp_missing
                    from base
                ),
                actual as (
                    select order_line_id, dq_category_missing
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_missing != a.dq_category_missing
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} category missing mismatches"
        finally:
            conn.close()

    def test_is_valid_composite(self, dbt_run):
        conn, db_type = get_db_connection()
        try:
            regexp_extract_expr = get_regexp_extract(db_type, 'pc.category_path', '([^>]+)$', 1)
            dayofweek_expr = get_dayofweek(db_type, 'order_ordered_at')
            quantile_25 = get_quantile_cont(db_type, 'net_unit_price', 0.25)
            quantile_75 = get_quantile_cont(db_type, 'net_unit_price', 0.75)
            email_regex = get_regexp_matches(db_type, 'text_val', '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\\\.[a-zA-Z]{2,}')
            phone_regex = get_regexp_matches(db_type, 'text_val', '\\\\b\\\\d{3}[-.]?\\\\d{3}[-.]?\\\\d{4}\\\\b')
            ssn_regex = get_regexp_matches(db_type, 'text_val', '\\\\b\\\\d{3}-\\\\d{2}-\\\\d{4}\\\\b')
            cc_regex = get_regexp_matches(db_type, 'text_val', '\\\\b\\\\d{4}[- ]?\\\\d{4}[- ]?\\\\d{4}[- ]?\\\\d{4}\\\\b')
            mismatches = execute_query(conn, db_type, f"""
                with base as (
                    select
                        ol.order_line_id,
                        o.order_id,
                        o.order_number,
                        coalesce(nullif(trim(pv.sku), ''), nullif(trim(ol.sku), '')) as sku,
                        coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), '')) as product_name,
                        case
                            when pc.category_path is not null and trim(pc.category_path) != ''
                                then trim({regexp_extract_expr})
                            when pc.category_name is not null and trim(pc.category_name) != ''
                                then trim(pc.category_name)
                            else coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), ''))
                        end as product_category_leaf,
                        p.primary_category_id,
                        pc.category_id as category_id,
                        pc.category_name as category_name,
                        ol.quantity_ordered,
                        ol.quantity_shipped,
                        ol.quantity_returned,
                        ol.unit_price,
                        ol.discount_amount,
                        ol.tax_amount,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount) as line_total,
                        (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                            - ol.quantity_ordered * coalesce(pv.cost_price, 0) as line_profit,
                        round((ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                              / nullif(ol.quantity_ordered, 0), 2) as net_unit_price,
                        case
                            when ol.status in ('CREDIT','RETURNED')
                            then abs(ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                            else (ol.quantity_ordered * ol.unit_price - ol.discount_amount + ol.tax_amount)
                        end as amount,
                        case
                            when ol.status in ('CREDIT','RETURNED')
                            then abs(ol.quantity_ordered)
                            else ol.quantity_ordered
                        end as qty,
                        ol.status as line_status,
                        ol.updated_at as line_updated_at,
                        ol.created_at as line_created_at,
                        o.ordered_at as order_ordered_at,
                        o.grand_total,
                        coalesce(o.notes, o.analyst_notes) as text_val,
                        ol.product_id
                    from {MODEL_SCHEMA}.stg_orders__order_lines ol
                    left join {MODEL_SCHEMA}.stg_orders__orders o on ol.order_id = o.order_id
                    left join {MODEL_SCHEMA}.stg_product__product_variants pv on ol.variant_id = pv.variant_id
                    left join {MODEL_SCHEMA}.stg_product__products p on pv.product_id = p.product_id
                    left join {MODEL_SCHEMA}.stg_product__product_categories pc on p.primary_category_id = pc.category_id
                ),
                stats as (
                    select
                        product_id,
                        {quantile_25} as p25,
                        {quantile_75} as p75
                    from base
                    where line_status not in ('CREDIT','RETURNED')
                    group by product_id
                ),
                flags as (
                    select
                        b.order_line_id,
                        case
                            when order_line_id is null
                              or trim(cast(order_line_id as varchar)) = ''
                              or order_id is null
                              or trim(cast(order_id as varchar)) = ''
                              or order_number is null
                              or trim(cast(order_number as varchar)) = ''
                              or sku is null
                              or trim(cast(sku as varchar)) = ''
                              or product_name is null
                              or trim(cast(product_name as varchar)) = ''
                              or product_category_leaf is null
                              or trim(cast(product_category_leaf as varchar)) = ''
                              or quantity_ordered is null
                              or unit_price is null
                              or line_total is null
                              or net_unit_price is null
                            then true
                            else false
                        end as missing_required,
                        case
                            when line_status = 'CREDIT' then true
                            when line_total is null then true
                            when line_total < 0 then false
                            else true
                        end as line_total_nonnegative,
                        case
                            when quantity_shipped is null or quantity_ordered is null then true
                            when quantity_shipped > quantity_ordered * 1.05 then false
                            else true
                        end as shipped_vs_ordered_valid,
                        case
                            when line_status = 'RETURNED' and (quantity_returned is null or quantity_shipped is null) then true
                            when line_status = 'RETURNED' and quantity_returned > quantity_shipped then false
                            when line_status = 'RETURNED' then true
                            else true
                        end as return_vs_shipped_valid,
                        case
                            when line_status = 'PENDING' then (coalesce(quantity_shipped, 0) = 0 and coalesce(quantity_returned, 0) = 0)
                            when line_status = 'SHIPPED' then quantity_shipped > 0
                            when line_status = 'RETURNED' then quantity_returned > 0
                            when line_status = 'CREDIT' then quantity_ordered < 0 and line_total < 0
                            else true
                        end as status_qty_valid,
                        case
                            when abs(grand_total - sum(case when line_status = 'CREDIT'
                                                            then 0
                                                            else line_total
                                                       end) over (partition by order_id)) > 0.01
                            then false
                            else true
                        end as order_total_match,
                        case
                            when amount < 0 then 'NEGATIVE_AMOUNT'
                            when amount = 0 then 'ZERO_AMOUNT'
                            when amount > 10000 then 'HIGH_AMOUNT'
                            when amount = round(amount, 0)
                                 and amount > 100
                                 and mod(cast(amount as integer), 100) = 0 then 'ROUND_NUMBER_SUSPECT'
                            when {dayofweek_expr} in (0, 6)
                                 and amount > 5000 then 'WEEKEND_HIGH_AMOUNT'
                            else null
                        end as revenue_flag,
                        case
                            when qty is null then 'NULL_QUANTITY'
                            when qty < 0 then 'NEGATIVE_QUANTITY'
                            when qty = 0 then 'ZERO_QUANTITY'
                            when qty > 10000 then 'BULK_ORDER'
                            when qty != round(qty, 0) then 'FRACTIONAL_QUANTITY'
                            else null
                        end as quantity_flag,
                        case
                            when line_status in ('CREDIT','RETURNED') then null
                            when b.net_unit_price < (s.p25 - 1.5 * (s.p75 - s.p25)) then 'LOW_OUTLIER'
                            when b.net_unit_price > (s.p75 + 1.5 * (s.p75 - s.p25)) then 'HIGH_OUTLIER'
                            else null
                        end as unit_price_iqr_flag,
                        case
                            when {email_regex} then 'CONTAINS_EMAIL'
                            when {phone_regex} then 'CONTAINS_PHONE'
                            when {ssn_regex} then 'CONTAINS_SSN'
                            when {cc_regex} then 'CONTAINS_CC'
                            else null
                        end as pii_flag,
                        case
                            when count(*) over (partition by order_id, b.product_id) > 1 then true
                            else false
                        end as duplicate_suspected
                        ,
                        case
                            when order_ordered_at is not null
                              and line_created_at is not null
                              and order_ordered_at > line_created_at then false
                            when line_created_at is not null
                              and line_updated_at is not null
                              and line_created_at > line_updated_at then false
                            else true
                        end as line_dates_valid,
                        case
                            when primary_category_id is null then true
                            when category_id is null then true
                            when category_name is null or trim(category_name) = '' then true
                            else false
                        end as category_missing,
                        case
                            when line_status in ('CREDIT','RETURNED') then null
                            when discount_amount / nullif(unit_price * quantity_ordered, 0) is null then null
                            when discount_amount / nullif(unit_price * quantity_ordered, 0) < 0 then 'NEGATIVE_DISCOUNT'
                            when discount_amount / nullif(unit_price * quantity_ordered, 0) > 1 then 'DISCOUNT_EXCEEDS_PRICE'
                            when discount_amount / nullif(unit_price * quantity_ordered, 0) > 0.70 then 'HIGH_DISCOUNT'
                            else null
                        end as discount_rate_flag,
                        case
                            when line_status in ('CREDIT','RETURNED') then null
                            when line_total = 0 then 'ZERO_REVENUE'
                            when line_profit < 0 then 'NEGATIVE_MARGIN'
                            when line_profit / nullif(line_total, 0) > 0.80 then 'EXCESS_MARGIN'
                            else null
                        end as margin_flag
                    from base b
                    left join stats s on b.product_id = s.product_id
                ),
                expected as (
                    select
                        order_line_id,
                        case
                            when missing_required = true then false
                            when line_total_nonnegative = false then false
                            when shipped_vs_ordered_valid = false then false
                            when return_vs_shipped_valid = false then false
                            when status_qty_valid = false then false
                            when order_total_match = false then false
                            when line_dates_valid = false then false
                            when category_missing = true then false
                            when revenue_flag is not null then false
                            when quantity_flag is not null then false
                            when unit_price_iqr_flag is not null then false
                            when pii_flag is not null then false
                            when discount_rate_flag is not null then false
                            when margin_flag is not null then false
                            when duplicate_suspected = true then false
                            else true
                        end as exp_is_valid
                    from flags
                ),
                actual as (
                    select order_line_id, dq_is_valid
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.order_line_id = a.order_line_id
                where e.exp_is_valid != a.dq_is_valid
            """)[0][0]
            assert mismatches == 0, f"Found {mismatches} dq_is_valid mismatches"
        finally:
            conn.close()
