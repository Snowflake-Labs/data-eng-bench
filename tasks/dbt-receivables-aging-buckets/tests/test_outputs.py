"""
Tests for fact_receivables_aging model (payments + credits).
"""
import subprocess
import os
import pytest

MODEL_NAME = "fact_receivables_aging"
REFERENCE_DATE_PHASE1 = "2026-06-30"
REFERENCE_DATE_PHASE2 = "2026-07-05"
MUTATION_STATE = {}

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

DB_TYPE = os.environ.get('DB_TYPE', 'duckdb').lower()

if DB_TYPE == 'snowflake':
    MODEL_SCHEMA = 'main'
else:
    MODEL_SCHEMA = "main"


def get_dayofweek_sql(date_expr):
    """Return database-specific dayofweek SQL"""
    if DB_TYPE == 'snowflake':
        return f"DAYOFWEEK({date_expr})"
    else:
        return f"dayofweek({date_expr})"


def get_datediff_sql(unit, start_date, end_date):
    """Return database-specific date diff SQL"""
    if DB_TYPE == 'snowflake':
        return f"DATEDIFF('{unit}', {start_date}, {end_date})"
    else:
        return f"date_diff('{unit}', {start_date}, {end_date})"


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


def get_db_connection(read_only=True):
    """Create a database connection based on DB_TYPE environment variable"""
    if DB_TYPE == 'snowflake':
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
            return conn
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
        return conn
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        return duckdb.connect(db_path, read_only=read_only)


def execute_query(conn, query, params=None):
    """Execute a query and return results, handling differences between DuckDB and Snowflake"""
    if DB_TYPE == 'snowflake':
        import re
        if params:
            query = query.replace('?', '%s')
        # Convert DuckDB INTERVAL plural to Snowflake singular
        query = re.sub(r"interval\s+'(\d+)\s+days'", r"interval '\1 day'", query, flags=re.IGNORECASE)
        # Cast %s params used with INTERVAL to DATE (Snowflake binds are VARCHAR)
        query = re.sub(r'%s\s*([\+\-])\s*interval', r'CAST(%s AS DATE) \1 interval', query, flags=re.IGNORECASE)
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


def execute_scalar(conn, query, params=None):
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, query, params)
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
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def mutate_source_data(phase):
    conn = get_db_connection(read_only=False)
    try:
        state = MUTATION_STATE
        if phase == 1:
            invoice_ids = [
                r[0]
                for r in execute_query(
                    conn,
                    """
                    select invoice_id
                    from finance.customer_invoices
                    order by invoice_id
                    limit 8
                    """,
                )
            ]
            state["inv_due_null"] = invoice_ids[0]
            state["inv_due_early"] = invoice_ids[1]
            state["inv_total_mismatch"] = invoice_ids[2]
            state["inv_null_subtotal"] = invoice_ids[3]
            state["inv_null_tax"] = invoice_ids[4]
            state["inv_invoice_date_late"] = invoice_ids[5]
            if len(invoice_ids) > 6:
                state["inv_due_boundary"] = invoice_ids[6]

            execute_query(
                conn,
                "update finance.customer_invoices set due_date = null where invoice_id = ?",
                [state["inv_due_null"]],
            )
            execute_query(
                conn,
                """
                update finance.customer_invoices
                set due_date = invoice_date - interval '5 days'
                where invoice_id = ?
                """,
                [state["inv_due_early"]],
            )
            execute_query(
                conn,
                """
                update finance.customer_invoices
                set total_amount = subtotal + tax_amount + 100
                where invoice_id = ?
                """,
                [state["inv_total_mismatch"]],
            )
            execute_query(
                conn,
                "update finance.customer_invoices set subtotal = null where invoice_id = ?",
                [state["inv_null_subtotal"]],
            )
            execute_query(
                conn,
                "update finance.customer_invoices set tax_amount = null where invoice_id = ?",
                [state["inv_null_tax"]],
            )
            execute_query(
                conn,
                """
                update finance.customer_invoices
                set invoice_date = cast(created_at as date) + interval '10 days',
                    due_date = cast(created_at as date) + interval '40 days'
                where invoice_id = ?
                """,
                [state["inv_invoice_date_late"]],
            )
            if state.get("inv_due_boundary"):
                execute_query(
                    conn,
                    """
                    update finance.customer_invoices
                    set invoice_date = date '2026-05-01',
                        due_date = date '2026-06-03'
                    where invoice_id = ?
                    """,
                    [state["inv_due_boundary"]],
                )

            inv_no_apps = execute_query(
                conn,
                """
                select i.invoice_id
                from finance.customer_invoices i
                left join finance.customer_payment_applications a
                  on i.invoice_id = a.invoice_id
                where a.invoice_id is null
                order by i.invoice_id
                limit 1
                """,
            )
            inv_no_apps = inv_no_apps[0] if inv_no_apps else None
            if inv_no_apps:
                state["inv_no_apps"] = inv_no_apps[0]
                execute_query(
                    conn,
                    """
                    update finance.customer_invoices
                    set invoice_date = date '2026-05-01',
                        due_date = date '2026-06-03',
                        amount_paid = round(total_amount * 0.5, 2),
                        balance_due = total_amount - round(total_amount * 0.5, 2)
                    where invoice_id = ?
                    """,
                    [state["inv_no_apps"]],
                )

            payment_ids = [
                r[0]
                for r in execute_query(
                    conn,
                    """
                    select distinct p.payment_id
                    from finance.customer_payments p
                    join finance.customer_payment_applications a
                      on p.payment_id = a.payment_id
                    order by p.payment_id
                    limit 3
                    """,
                )
            ]
            if len(payment_ids) >= 1:
                state["void_payment_id"] = payment_ids[0]
                execute_query(
                    conn,
                    "update finance.customer_payments set status = 'VOID' where payment_id = ?",
                    [state["void_payment_id"]],
                )
            if len(payment_ids) >= 2:
                state["future_payment_id"] = payment_ids[1]
                execute_query(
                    conn,
                    """
                    update finance.customer_payments
                    set payment_date = date '2026-07-15'
                    where payment_id = ?
                    """,
                    [state["future_payment_id"]],
                )

            exclude_payment_ids = [
                pid
                for pid in (
                    state.get("void_payment_id"),
                    state.get("future_payment_id"),
                )
                if pid
            ]
            if exclude_payment_ids:
                placeholders = ",".join(["?"] * len(exclude_payment_ids))
                app_future = execute_query(
                    conn,
                    f"""
                    select application_id
                    from finance.customer_payment_applications
                    where payment_id not in ({placeholders})
                    order by application_id
                    limit 1
                    """,
                    exclude_payment_ids,
                )
            else:
                app_future = execute_query(
                    conn,
                    """
                    select application_id
                    from finance.customer_payment_applications
                    order by application_id
                    limit 1
                    """,
                )
            app_future = app_future[0] if app_future else None
            if app_future:
                state["app_future"] = app_future[0]
                execute_query(
                    conn,
                    """
                    update finance.customer_payment_applications
                    set applied_at = timestamp '2026-07-10'
                    where application_id = ?
                    """,
                    [state["app_future"]],
                )

            credit_customer = execute_query(
                conn,
                """
                select c.customer_id
                from finance.customer_credits c
                join finance.customer_invoices i on c.customer_id = i.customer_id
                group by c.customer_id
                having count(*) >= 4 and count(distinct i.invoice_id) >= 3
                order by c.customer_id
                limit 1
                """,
            )
            credit_customer = credit_customer[0] if credit_customer else None
            if not credit_customer:
                credit_customer = execute_query(
                    conn,
                    """
                    select c.customer_id
                    from finance.customer_credits c
                    join finance.customer_invoices i on c.customer_id = i.customer_id
                    group by c.customer_id
                    having count(*) >= 3 and count(distinct i.invoice_id) >= 3
                    order by c.customer_id
                    limit 1
                    """,
                )
                credit_customer = credit_customer[0] if credit_customer else None

            credit_ids = []
            if credit_customer:
                state["credit_customer"] = credit_customer[0]
                credit_ids = [
                    r[0]
                    for r in execute_query(
                        conn,
                        """
                        select credit_id
                        from finance.customer_credits
                        where customer_id = ?
                        order by credit_id
                        limit 4
                        """,
                        [state["credit_customer"]],
                    )
                ]
            if credit_ids:
                state["credit_high_id"] = credit_ids[0]
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set amount = 5000.00,
                        balance = 5000.00,
                        reason = 'Return',
                        created_at = coalesce(
                            (
                                select min(invoice_date) - interval '100 days'
                                from finance.customer_invoices
                                where customer_id = ?
                            ),
                            timestamp '2024-12-15'
                        )
                    where credit_id = ?
                    """,
                    [state["credit_customer"], state["credit_high_id"]],
                )
                if len(credit_ids) > 1:
                    state["credit_future_id"] = credit_ids[1]
                    execute_query(
                        conn,
                        """
                        update finance.customer_credits
                        set created_at = timestamp '2026-07-05',
                            reason = 'Refund'
                        where credit_id = ?
                        """,
                        [state["credit_future_id"]],
                    )
                if len(credit_ids) > 2:
                    state["credit_overbalance_id"] = credit_ids[2]
                    execute_query(
                        conn,
                        """
                        update finance.customer_credits
                        set amount = 100.00,
                            balance = 500.00,
                            reason = 'Adjustment'
                        where credit_id = ?
                        """,
                        [state["credit_overbalance_id"]],
                    )
                if len(credit_ids) > 3:
                    state["credit_promo_id"] = credit_ids[3]
                    execute_query(
                        conn,
                        """
                        update finance.customer_credits
                        set amount = 300.00,
                            balance = 300.00,
                            reason = 'Promotion'
                        where credit_id = ?
                        """,
                        [state["credit_promo_id"]],
                    )

            used_ids = [
                value
                for key, value in state.items()
                if key.startswith("credit_") and key.endswith("_id")
            ]
            if used_ids:
                placeholders = ",".join(["?"] * len(used_ids))
                query = (
                    "select credit_id from finance.customer_credits "
                    f"where credit_id not in ({placeholders}) "
                    "order by credit_id limit 1"
                )
                credit_null_date = execute_query(conn, query, used_ids)
                credit_null_date = credit_null_date[0] if credit_null_date else None
            else:
                credit_null_date = execute_query(
                    conn,
                    "select credit_id from finance.customer_credits order by credit_id limit 1",
                )
                credit_null_date = credit_null_date[0] if credit_null_date else None
            if credit_null_date:
                state["credit_null_date_id"] = credit_null_date[0]
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set created_at = null
                    where credit_id = ?
                    """,
                    [state["credit_null_date_id"]],
                )

            early_conditions = [
                "p.status = 'POSTED'",
                "p.payment_date <= date '2026-06-30'",
            ]
            early_params = []
            if state.get("void_payment_id"):
                early_conditions.append("a.payment_id != ?")
                early_params.append(state["void_payment_id"])
            if state.get("future_payment_id"):
                early_conditions.append("a.payment_id != ?")
                early_params.append(state["future_payment_id"])
            early_where = " and ".join(early_conditions)
            early_row = execute_query(
                conn,
                f"""
                select a.application_id, a.payment_id, a.invoice_id, i.invoice_date, i.total_amount
                from finance.customer_payment_applications a
                join finance.customer_invoices i on a.invoice_id = i.invoice_id
                join finance.customer_payments p on a.payment_id = p.payment_id
                where {early_where}
                order by a.application_id
                limit 1
                """,
                early_params,
            )
            early_row = early_row[0] if early_row else None
            if early_row:
                state["overapply_application_id"] = early_row[0]
                state["early_payment_id"] = early_row[1]
                state["early_invoice_id"] = early_row[2]
                state["early_invoice_date"] = early_row[3]
                state["overapply_invoice_total"] = early_row[4]
            exclude_invoices = [
                state.get("inv_due_null"),
                state.get("inv_due_early"),
                state.get("inv_total_mismatch"),
                state.get("inv_null_subtotal"),
                state.get("inv_null_tax"),
                state.get("inv_invoice_date_late"),
                state.get("inv_due_boundary"),
                state.get("early_invoice_id"),
            ]
            exclude_invoices = [inv for inv in exclude_invoices if inv]
            invoice_filter_sql = ""
            invoice_params = []
            if exclude_invoices:
                placeholders = ",".join(["?"] * len(exclude_invoices))
                invoice_filter_sql = f"and a.invoice_id not in ({placeholders})"
                invoice_params = exclude_invoices
            zero_apply_invoice = execute_query(
                conn,
                f"""
                select a.invoice_id
                from finance.customer_payment_applications a
                join finance.customer_payments p on a.payment_id = p.payment_id
                where p.status = 'POSTED'
                  and p.payment_date <= date '2026-06-30'
                  and cast(a.applied_at as date) <= date '2026-06-30'
                  {invoice_filter_sql}
                group by a.invoice_id
                having count(*) >= 2
                order by a.invoice_id
                limit 1
                """,
                invoice_params,
            )
            zero_apply_invoice = zero_apply_invoice[0] if zero_apply_invoice else None
            if zero_apply_invoice:
                state["zero_apply_invoice_id"] = zero_apply_invoice[0]
                app_rows = execute_query(
                    conn,
                    """
                    select a.application_id, a.payment_id
                    from finance.customer_payment_applications a
                    join finance.customer_payments p on a.payment_id = p.payment_id
                    where a.invoice_id = ?
                      and p.status = 'POSTED'
                      and p.payment_date <= date '2026-06-30'
                      and cast(a.applied_at as date) <= date '2026-06-30'
                    order by a.application_id
                    """,
                    [state["zero_apply_invoice_id"]],
                )
                state["zero_apply_app_ids"] = [r[0] for r in app_rows]
                if len(app_rows) >= 2:
                    state["dup_payment_id"] = app_rows[0][1]
                    state["dup_app_id"] = app_rows[1][0]
                    execute_query(
                        conn,
                        """
                        update finance.customer_payment_applications
                        set payment_id = ?
                        where application_id = ?
                        """,
                        [state["dup_payment_id"], state["dup_app_id"]],
                    )
                for app_id in state["zero_apply_app_ids"]:
                    execute_query(
                        conn,
                        """
                        update finance.customer_payment_applications
                        set amount_applied = 0
                        where application_id = ?
                        """,
                        [app_id],
                    )
                execute_query(
                    conn,
                    """
                    update finance.customer_invoices
                    set amount_paid = round((coalesce(subtotal, 0) + coalesce(tax_amount, 0)) * 0.25, 2),
                        balance_due = (coalesce(subtotal, 0) + coalesce(tax_amount, 0))
                                      - round((coalesce(subtotal, 0) + coalesce(tax_amount, 0)) * 0.25, 2)
                    where invoice_id = ?
                    """,
                    [state["zero_apply_invoice_id"]],
                )

        if phase == 2 and state:
            execute_query(
                conn,
                """
                update finance.customer_invoices
                set invoice_date = cast(created_at as date) - interval '10 days',
                    due_date = cast(created_at as date) + interval '20 days'
                where invoice_id = ?
                """,
                [state.get("inv_invoice_date_late")],
            )
            if state.get("inv_no_apps"):
                execute_query(
                    conn,
                    """
                    update finance.customer_invoices
                    set amount_paid = 0,
                        balance_due = total_amount
                    where invoice_id = ?
                    """,
                    [state["inv_no_apps"]],
                )

            if state.get("void_payment_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_payments
                    set status = 'POSTED',
                        payment_date = date '2026-06-10'
                    where payment_id = ?
                    """,
                    [state["void_payment_id"]],
                )
            if state.get("future_payment_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_payments
                    set payment_date = date '2026-06-20'
                    where payment_id = ?
                    """,
                    [state["future_payment_id"]],
                )
            if state.get("app_future"):
                execute_query(
                    conn,
                    """
                    update finance.customer_payment_applications
                    set applied_at = timestamp '2026-06-20'
                    where application_id = ?
                    """,
                    [state["app_future"]],
                )

            if state.get("early_payment_id") and state.get("early_invoice_date"):
                execute_query(
                    conn,
                    """
                    update finance.customer_payments
                    set payment_date = ? - interval '30 days'
                    where payment_id = ?
                    """,
                    [state["early_invoice_date"], state["early_payment_id"]],
                )

            if state.get("overapply_application_id") and state.get("overapply_invoice_total"):
                execute_query(
                    conn,
                    """
                    update finance.customer_payment_applications
                    set amount_applied = ? + 500.00
                    where application_id = ?
                    """,
                    [state["overapply_invoice_total"], state["overapply_application_id"]],
                )

            if state.get("credit_high_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set amount = 1200.00,
                        balance = 1200.00
                    where credit_id = ?
                    """,
                    [state["credit_high_id"]],
                )
            if state.get("credit_future_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set created_at = timestamp '2026-06-15'
                    where credit_id = ?
                    """,
                    [state["credit_future_id"]],
                )
            if state.get("credit_overbalance_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set amount = 400.00,
                        balance = 250.00
                    where credit_id = ?
                    """,
                    [state["credit_overbalance_id"]],
                )
            if state.get("credit_promo_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set reason = 'Refund',
                        balance = 150.00
                    where credit_id = ?
                    """,
                    [state["credit_promo_id"]],
                )
            if state.get("credit_null_date_id"):
                execute_query(
                    conn,
                    """
                    update finance.customer_credits
                    set created_at = timestamp '2026-06-01',
                        reason = 'Adjustment',
                        amount = -50.00,
                        balance = -50.00
                    where credit_id = ?
                    """,
                    [state["credit_null_date_id"]],
                )
            if state.get("zero_apply_invoice_id"):
                app_ids = state.get("zero_apply_app_ids", [])
                if app_ids:
                    for app_id in app_ids:
                        execute_query(
                            conn,
                            """
                            update finance.customer_payment_applications
                            set amount_applied = 0
                            where application_id = ?
                            """,
                            [app_id],
                        )
                    if len(app_ids) >= 2:
                        execute_query(
                            conn,
                            """
                            update finance.customer_payment_applications
                            set amount_applied = 75.00
                            where application_id = ?
                            """,
                            [app_ids[0]],
                        )
                        execute_query(
                            conn,
                            """
                            update finance.customer_payment_applications
                            set amount_applied = -75.00
                            where application_id = ?
                            """,
                            [app_ids[1]],
                        )
                    execute_query(
                        conn,
                        """
                        update finance.customer_invoices
                        set amount_paid = round((coalesce(subtotal, 0) + coalesce(tax_amount, 0)) * 0.60, 2),
                            balance_due = (coalesce(subtotal, 0) + coalesce(tax_amount, 0))
                                          - round((coalesce(subtotal, 0) + coalesce(tax_amount, 0)) * 0.60, 2)
                        where invoice_id = ?
                        """,
                        [state["zero_apply_invoice_id"]],
                    )
    finally:
        conn.close()


def run_dbt():
    mutate_source_data(phase=1)
    deps = run_cmd("dbt deps")
    if deps.returncode != 0:
        print(f"Warning: dbt deps failed: {deps.returncode}")
    res = run_cmd("dbt run --select fact_receivables_aging")
    assert res.returncode == 0, f"dbt run failed: {res.stderr}"

    mutate_source_data(phase=2)
    res = run_cmd(
        "dbt run --select fact_receivables_aging --vars \"{reference_date: '2026-07-05'}\""
    )
    assert res.returncode == 0, f"dbt run failed on re-run: {res.stderr}"


@pytest.fixture(scope="module")
def dbt_run():
    run_dbt()
    return True


class TestReceivablesAging:
    def test_columns_present(self, dbt_run):
        conn = get_db_connection()
        try:
            cols = execute_query(
                conn,
                f"""
                select column_name from information_schema.columns
                where lower(table_schema) = lower('{MODEL_SCHEMA}')
                  and lower(table_name) = lower('{MODEL_NAME}')
                """,
            )
            names = {c[0].lower() for c in cols}
            required = {
                "invoice_id",
                "invoice_number",
                "customer_id",
                "invoice_date",
                "due_date",
                "business_reference_date",
                "customer_first_activity_date",
                "effective_invoice_date",
                "effective_due_date",
                "subtotal",
                "tax_amount",
                "total_amount",
                "applied_amount",
                "first_payment_date",
                "overapplied_amount",
                "gross_outstanding_amount",
                "customer_credit_balance",
                "overapplied_credit_pool",
                "total_credit_pool",
                "credit_applied",
                "outstanding_amount",
                "payment_count",
                "latest_payment_date",
                "payment_status",
                "days_past_due",
                "aging_bucket",
            }
            missing = required - names
            assert not missing, f"Missing columns: {missing}"
        finally:
            conn.close()

    def test_unique_invoice_id(self, dbt_run):
        conn = get_db_connection()
        try:
            dupes = execute_query(
                conn,
                f"""
                select count(*)
                from (
                    select invoice_id, count(*) as c
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                    group by invoice_id
                    having count(*) > 1
                )
                """,
            )
            assert dupes[0][0] == 0, f"Found {dupes[0][0]} duplicate invoice_id values"
        finally:
            conn.close()

    def test_row_count_matches_invoices(self, dbt_run):
        conn = get_db_connection()
        try:
            expected = execute_scalar(
                conn,
                f"select count(*) from {MODEL_SCHEMA}.stg_finance__customer_invoices",
            )
            actual = execute_scalar(
                conn,
                f"select count(*) from {MODEL_SCHEMA}.{MODEL_NAME}",
            )
            assert expected == actual, f"Row count mismatch: expected {expected}, got {actual}"
        finally:
            conn.close()

    def test_calculations_match_expected(self, dbt_run):
        conn = get_db_connection()
        try:
            # Build database-specific SQL
            dayofweek_sql = get_dayofweek_sql(f"date '{REFERENCE_DATE_PHASE2}'")
            datediff_sql = get_datediff_sql('day', 'effective_due_date', 'business_reference_date')

            mismatches = execute_scalar(
                conn,
                f"""
                with params as (
                    select
                        date '{REFERENCE_DATE_PHASE2}' as reference_date,
                        case
                            when {dayofweek_sql} = 6 then date '{REFERENCE_DATE_PHASE2}' - interval '1 day'
                            when {dayofweek_sql} = 0 then date '{REFERENCE_DATE_PHASE2}' - interval '2 days'
                            else date '{REFERENCE_DATE_PHASE2}'
                        end as business_reference_date
                ),
                base as (
                    select
                        invoice_id,
                        invoice_number,
                        customer_id,
                        invoice_date,
                        due_date,
                        subtotal,
                        tax_amount,
                        amount_paid,
                        created_at,
                        p.business_reference_date
                    from {MODEL_SCHEMA}.stg_finance__customer_invoices b
                    cross join params p
                ),
                apps as (
                    select
                        application_id,
                        payment_id,
                        invoice_id,
                        amount_applied,
                        applied_at
                    from {MODEL_SCHEMA}.stg_finance__customer_payment_applications
                ),
                payments as (
                    select payment_id, payment_date, status
                    from {MODEL_SCHEMA}.stg_finance__customer_payments
                ),
                filtered_apps as (
                    select a.*
                    from apps a
                    join payments p on a.payment_id = p.payment_id
                    cross join params r
                    where p.status = 'POSTED'
                      and p.payment_date <= r.business_reference_date
                      and cast(a.applied_at as date) <= r.business_reference_date
                ),
                app_agg as (
                    select
                        a.invoice_id,
                        count(distinct a.payment_id) as payment_count,
                        min(p.payment_date) as first_payment_date,
                        max(p.payment_date) as latest_payment_date,
                        sum(a.amount_applied) as applied_amount_raw
                    from filtered_apps a
                    join payments p on a.payment_id = p.payment_id
                    group by a.invoice_id
                ),
                calc as (
                    select
                        b.*,
                        coalesce(app_agg.applied_amount_raw, 0) as applied_amount_raw,
                        coalesce(app_agg.payment_count, 0) as payment_count,
                        app_agg.first_payment_date,
                        app_agg.latest_payment_date,
                        coalesce(subtotal, 0) + coalesce(tax_amount, 0) as total_amount,
                        case
                            when coalesce(app_agg.applied_amount_raw, 0) = 0
                                then coalesce(b.amount_paid, 0)
                            else coalesce(app_agg.applied_amount_raw, 0)
                        end as applied_amount,
                        case
                            when b.invoice_date is null and b.created_at is null and app_agg.first_payment_date is null and b.due_date is null then null
                            when b.invoice_date is null and b.created_at is null and app_agg.first_payment_date is null then b.due_date
                            else least(
                                coalesce(b.invoice_date, date '9999-12-31'),
                                coalesce(cast(b.created_at as date), date '9999-12-31'),
                                coalesce(app_agg.first_payment_date, date '9999-12-31')
                            )
                        end as effective_invoice_date
                    from base b
                    left join app_agg on b.invoice_id = app_agg.invoice_id
                ),
                with_due as (
                    select
                        *,
                        case
                            when due_date is not null
                                 and effective_invoice_date is not null
                                 and due_date >= effective_invoice_date then due_date
                            when effective_invoice_date is not null then effective_invoice_date + interval '30 days'
                            else null
                        end as effective_due_date
                    from calc
                ),
                metrics as (
                    select
                        *,
                        greatest(applied_amount - total_amount, 0) as overapplied_amount,
                        total_amount - least(applied_amount, total_amount) as gross_outstanding_amount
                    from with_due
                ),
                credits as (
                    select
                        customer_id,
                        reason,
                        greatest(least(coalesce(balance, amount), amount), 0) as credit_available,
                        created_at
                    from {MODEL_SCHEMA}.stg_finance__customer_credits
                ),
                credit_filtered as (
                    select *
                    from credits
                    cross join params r
                    where reason in ('Refund', 'Return', 'Adjustment', 'Promotion')
                      and created_at is not null
                      and cast(created_at as date) <= r.business_reference_date
                ),
                credit_agg as (
                    select
                        customer_id,
                        sum(credit_available) as customer_credit_balance
                    from credit_filtered
                    group by customer_id
                ),
                overapplied_pool as (
                    select
                        customer_id,
                        sum(overapplied_amount) as overapplied_credit_pool
                    from metrics
                    group by customer_id
                ),
                customer_activity as (
                    select
                        b.customer_id,
                        min(b.invoice_date) as min_invoice_date,
                        min(cast(b.created_at as date)) as min_created_date,
                        min(a.first_payment_date) as min_payment_date
                    from base b
                    left join app_agg a on b.invoice_id = a.invoice_id
                    group by b.customer_id
                ),
                credit_min as (
                    select
                        customer_id,
                        min(cast(created_at as date)) as min_credit_date
                    from credit_filtered
                    group by customer_id
                ),
                customer_first as (
                    select
                        ca.customer_id,
                        case
                            when ca.min_invoice_date is null
                                 and ca.min_created_date is null
                                 and ca.min_payment_date is null
                                 and cm.min_credit_date is null then null
                            else least(
                                coalesce(ca.min_invoice_date, date '9999-12-31'),
                                coalesce(ca.min_created_date, date '9999-12-31'),
                                coalesce(ca.min_payment_date, date '9999-12-31'),
                                coalesce(cm.min_credit_date, date '9999-12-31')
                            )
                        end as customer_first_activity_date
                    from customer_activity ca
                    left join credit_min cm on ca.customer_id = cm.customer_id
                ),
                pool as (
                    select
                        m.*,
                        coalesce(ca.customer_credit_balance, 0) as customer_credit_balance,
                        coalesce(op.overapplied_credit_pool, 0) as overapplied_credit_pool,
                        coalesce(ca.customer_credit_balance, 0) + coalesce(op.overapplied_credit_pool, 0) as total_credit_pool,
                        cf.customer_first_activity_date
                    from metrics m
                    left join credit_agg ca on m.customer_id = ca.customer_id
                    left join overapplied_pool op on m.customer_id = op.customer_id
                    left join customer_first cf on m.customer_id = cf.customer_id
                ),
                alloc as (
                    select
                        p.*,
                        sum(p.gross_outstanding_amount) over (
                            partition by p.customer_id
                            order by p.effective_due_date asc nulls last,
                                     p.effective_invoice_date asc nulls last,
                                     p.invoice_id asc
                            rows between unbounded preceding and current row
                        ) as cum_outstanding
                    from pool p
                ),
                final as (
                    select
                        invoice_id,
                        invoice_number,
                        customer_id,
                        invoice_date,
                        due_date,
                        business_reference_date,
                        customer_first_activity_date,
                        cast(effective_invoice_date as date) as effective_invoice_date,
                        cast(effective_due_date as date) as effective_due_date,
                        subtotal,
                        tax_amount,
                        total_amount,
                        applied_amount,
                        first_payment_date,
                        overapplied_amount,
                        gross_outstanding_amount,
                        customer_credit_balance,
                        overapplied_credit_pool,
                        total_credit_pool,
                        case
                            when gross_outstanding_amount <= 0 or total_credit_pool <= 0 then 0
                            else greatest(
                                least(total_credit_pool - (cum_outstanding - gross_outstanding_amount), gross_outstanding_amount),
                                0
                            )
                        end as credit_applied,
                        payment_count,
                        latest_payment_date
                    from alloc
                ),
                expected as (
                    select
                        *,
                        gross_outstanding_amount - credit_applied as outstanding_amount,
                        case
                            when overapplied_amount > 0 then 'CREDIT'
                            when gross_outstanding_amount - credit_applied = 0 then 'PAID'
                            else 'OPEN'
                        end as payment_status,
                        case
                            when gross_outstanding_amount - credit_applied = 0 then 0
                            else {datediff_sql}
                        end as days_past_due,
                        case
                            when overapplied_amount > 0 then 'CREDIT'
                            when gross_outstanding_amount - credit_applied = 0 then 'PAID'
                            when {datediff_sql} < 0 then 'CURRENT'
                            when {datediff_sql} between 0 and 30 then '0-30'
                            when {datediff_sql} between 31 and 60 then '31-60'
                            when {datediff_sql} between 61 and 90 then '61-90'
                            when {datediff_sql} between 91 and 120 then '91-120'
                            else '120+'
                        end as aging_bucket
                    from final
                ),
                actual as (
                    select
                        invoice_id,
                        invoice_number,
                        customer_id,
                        invoice_date,
                        due_date,
                        business_reference_date,
                        customer_first_activity_date,
                        cast(effective_invoice_date as date) as effective_invoice_date,
                        cast(effective_due_date as date) as effective_due_date,
                        subtotal,
                        tax_amount,
                        total_amount,
                        applied_amount,
                        first_payment_date,
                        overapplied_amount,
                        gross_outstanding_amount,
                        customer_credit_balance,
                        overapplied_credit_pool,
                        total_credit_pool,
                        credit_applied,
                        outstanding_amount,
                        payment_count,
                        latest_payment_date,
                        payment_status,
                        days_past_due,
                        aging_bucket
                    from {MODEL_SCHEMA}.{MODEL_NAME}
                )
                select count(*)
                from expected e
                join actual a on e.invoice_id = a.invoice_id
                where
                    e.invoice_number is distinct from a.invoice_number or
                    e.customer_id is distinct from a.customer_id or
                    e.invoice_date is distinct from a.invoice_date or
                    e.due_date is distinct from a.due_date or
                    e.business_reference_date is distinct from a.business_reference_date or
                    e.customer_first_activity_date is distinct from a.customer_first_activity_date or
                    e.effective_invoice_date is distinct from a.effective_invoice_date or
                    e.effective_due_date is distinct from a.effective_due_date or
                    round(e.subtotal, 4) is distinct from round(a.subtotal, 4) or
                    round(e.tax_amount, 4) is distinct from round(a.tax_amount, 4) or
                    round(e.total_amount, 4) is distinct from round(a.total_amount, 4) or
                    round(e.applied_amount, 4) is distinct from round(a.applied_amount, 4) or
                    e.first_payment_date is distinct from a.first_payment_date or
                    round(e.overapplied_amount, 4) is distinct from round(a.overapplied_amount, 4) or
                    round(e.gross_outstanding_amount, 4) is distinct from round(a.gross_outstanding_amount, 4) or
                    round(e.customer_credit_balance, 4) is distinct from round(a.customer_credit_balance, 4) or
                    round(e.overapplied_credit_pool, 4) is distinct from round(a.overapplied_credit_pool, 4) or
                    round(e.total_credit_pool, 4) is distinct from round(a.total_credit_pool, 4) or
                    round(e.credit_applied, 4) is distinct from round(a.credit_applied, 4) or
                    round(e.outstanding_amount, 4) is distinct from round(a.outstanding_amount, 4) or
                    e.payment_count is distinct from a.payment_count or
                    e.latest_payment_date is distinct from a.latest_payment_date or
                    e.payment_status is distinct from a.payment_status or
                    e.days_past_due is distinct from a.days_past_due or
                    e.aging_bucket is distinct from a.aging_bucket
                """,
            )
            assert mismatches == 0, f"Found {mismatches} mismatched rows"
        finally:
            conn.close()
