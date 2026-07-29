#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile - uses private key authentication
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"
else
    # DuckDB profile (default)
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps

mkdir -p models/marts/finance

cat > models/marts/finance/fact_receivables_aging.sql <<'SQL'
{{
    config(
        materialized='table',
        tags=['mart', 'finance', 'receivables', 'payments', 'credits']
    )
}}

{% set reference_date = var('reference_date', '2026-06-30') %}

with params as (
    select
        date '{{ reference_date }}' as reference_date,
        case
            {% if target.type == 'snowflake' %}
            when DAYOFWEEK(date '{{ reference_date }}') = 6 then date '{{ reference_date }}' - interval '1 day'
            when DAYOFWEEK(date '{{ reference_date }}') = 0 then date '{{ reference_date }}' - interval '2 days'
            {% else %}
            when dayofweek(date '{{ reference_date }}') = 6 then date '{{ reference_date }}' - interval '1 day'
            when dayofweek(date '{{ reference_date }}') = 0 then date '{{ reference_date }}' - interval '2 days'
            {% endif %}
            else date '{{ reference_date }}'
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
    from {{ ref('stg_finance__customer_invoices') }} b
    cross join params p
),

apps as (
    select
        application_id,
        payment_id,
        invoice_id,
        amount_applied,
        applied_at
    from {{ ref('stg_finance__customer_payment_applications') }}
),

payments as (
    select
        payment_id,
        payment_date,
        status
    from {{ ref('stg_finance__customer_payments') }}
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
    from {{ ref('stg_finance__customer_credits') }}
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

final_metrics as (
    select
        *,
        gross_outstanding_amount - credit_applied as outstanding_amount
    from final
)

select
    invoice_id,
    invoice_number,
    customer_id,
    invoice_date,
    due_date,
    business_reference_date,
    customer_first_activity_date,
    effective_invoice_date,
    effective_due_date,
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
    case
        when overapplied_amount > 0 then 'CREDIT'
        when outstanding_amount = 0 then 'PAID'
        else 'OPEN'
    end as payment_status,
    case
        when outstanding_amount = 0 then 0
        {% if target.type == 'snowflake' %}
        else DATEDIFF('day', effective_due_date, business_reference_date)
        {% else %}
        else date_diff('day', effective_due_date, business_reference_date)
        {% endif %}
    end as days_past_due,
    case
        when overapplied_amount > 0 then 'CREDIT'
        when outstanding_amount = 0 then 'PAID'
        {% if target.type == 'snowflake' %}
        when DATEDIFF('day', effective_due_date, business_reference_date) < 0 then 'CURRENT'
        when DATEDIFF('day', effective_due_date, business_reference_date) between 0 and 30 then '0-30'
        when DATEDIFF('day', effective_due_date, business_reference_date) between 31 and 60 then '31-60'
        when DATEDIFF('day', effective_due_date, business_reference_date) between 61 and 90 then '61-90'
        when DATEDIFF('day', effective_due_date, business_reference_date) between 91 and 120 then '91-120'
        {% else %}
        when date_diff('day', effective_due_date, business_reference_date) < 0 then 'CURRENT'
        when date_diff('day', effective_due_date, business_reference_date) between 0 and 30 then '0-30'
        when date_diff('day', effective_due_date, business_reference_date) between 31 and 60 then '31-60'
        when date_diff('day', effective_due_date, business_reference_date) between 61 and 90 then '61-90'
        when date_diff('day', effective_due_date, business_reference_date) between 91 and 120 then '91-120'
        {% endif %}
        else '120+'
    end as aging_bucket
from final_metrics
SQL

# Run the model

dbt run --select fact_receivables_aging


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set db = target.database %}
  {% do run_query('USE DATABASE "' ~ db ~ '"') %}
  {% do run_query('CREATE SCHEMA IF NOT EXISTS "' ~ db ~ '"."main"') %}
  {% set tables = [
    'fact_receivables_aging'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "' ~ db ~ '"."main"."' ~ t ~ '" AS SELECT * FROM "' ~ db ~ '".MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
