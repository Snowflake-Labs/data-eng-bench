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
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
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
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

# Navigate to dbt project
cd "$DBT_PROJECT_DIR"

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
      schema: main
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

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Install dbt dependencies
dbt deps

# Ensure marts directory exists
mkdir -p models/marts

# Create the comprehensive supplier payment optimization model
cat > models/marts/supplier_payment_optimization.sql << 'EOF'
/*
Supplier Payment Optimization with Dynamic Discount Analysis and Risk Assessment

This model analyzes supplier invoices to optimize payment timing, calculate early
payment discount opportunities, assess supplier risk, compute annualized ROI on
discounts, and project cash outflow schedules with weighted prioritization.

All logic is contained within a single SQL file using CTEs to demonstrate
complex analytical SQL skills.
*/

{{ config(materialized='table') }}

with analysis_params as (
    -- Define analysis date parameter
    select DATE '2024-12-31' as analysis_date
),

-- Get supplier invoices with status filter
invoices as (
    select
        invoice_id,
        invoice_number,
        supplier_id,
        po_id,
        invoice_date,
        due_date,
        total_amount as invoice_amount,
        currency_code,
        status
    from {{ ref('stg_procurement__supplier_invoices') }}
    where status in ('OPEN', 'PENDING')
),

-- Get supplier information with payment terms
suppliers as (
    select
        supplier_id,
        supplier_code,
        supplier_name,
        supplier_type,
        payment_terms,
        coalesce(rating, 3.0) as rating,
        status
    from {{ ref('stg_procurement__suppliers') }}
),

-- Get the most recent exchange rate for each currency before or on a given date
exchange_rates as (
    select
        from_currency,
        to_currency,
        exchange_rate,
        effective_date
    from {{ ref('stg_finance__currency_exchange_rates') }}
    where to_currency = 'USD'
),

-- Join invoices with suppliers
invoice_supplier as (
    select
        i.invoice_id,
        i.invoice_number,
        i.supplier_id,
        s.supplier_name,
        s.rating as supplier_rating,
        s.payment_terms as payment_terms_code,
        i.invoice_date,
        i.due_date,
        i.invoice_amount,
        i.currency_code,
        i.status
    from invoices i
    inner join suppliers s on i.supplier_id = s.supplier_id
),

-- Get exchange rate for each invoice (most recent rate on or before invoice date)
{% if target.type == 'snowflake' %}
latest_rates as (
    select
        inv.invoice_id,
        er.exchange_rate,
        row_number() over (
            partition by inv.invoice_id
            order by er.effective_date desc
        ) as rn
    from invoice_supplier inv
    inner join exchange_rates er
        on er.from_currency = inv.currency_code
        and er.effective_date <= inv.invoice_date
    where inv.currency_code != 'USD'
),

invoice_with_rate as (
    select
        inv.*,
        case
            when inv.currency_code = 'USD' then 1.0
            else lr.exchange_rate
        end as exchange_rate
    from invoice_supplier inv
    left join latest_rates lr
        on lr.invoice_id = inv.invoice_id
        and lr.rn = 1
    where inv.currency_code = 'USD'
       or lr.exchange_rate is not null
),
{% else %}
invoice_with_rate as (
    select
        inv.*,
        case
            when inv.currency_code = 'USD' then 1.0
            else er.exchange_rate
        end as exchange_rate
    from invoice_supplier inv
    left join lateral (
        select exchange_rate
        from exchange_rates
        where from_currency = inv.currency_code
          and effective_date <= inv.invoice_date
        order by effective_date desc
        limit 1
    ) er on true
    where inv.currency_code = 'USD'
       or er.exchange_rate is not null
),
{% endif %}

-- Convert to USD and calculate days until due
invoice_usd as (
    select
        inv.*,
        round(inv.invoice_amount * inv.exchange_rate, 2) as amount_usd,
        p.analysis_date,
        cast(inv.due_date - p.analysis_date as integer) as days_until_due,
        cast(p.analysis_date - inv.invoice_date as integer) as days_since_invoice
    from invoice_with_rate inv
    cross join analysis_params p
),

-- Calculate total payables for concentration calculation
total_payables as (
    select sum(amount_usd) as total_amount_usd
    from invoice_usd
),

-- Assign aging buckets
invoice_aging as (
    select
        inv.*,
        tp.total_amount_usd,
        case
            when days_until_due > 0 then 'Not Yet Due'
            when days_until_due >= -30 and days_until_due <= 0 then '1-30 Days Overdue'
            when days_until_due >= -60 and days_until_due < -30 then '31-60 Days Overdue'
            when days_until_due >= -90 and days_until_due < -60 then '61-90 Days Overdue'
            else 'Over 90 Days Overdue'
        end as aging_bucket
    from invoice_usd inv
    cross join total_payables tp
),

-- Parse early payment discount terms
-- Formats: "2/10 Net 30", "1/15 Net 45", "Net 30", etc.
invoice_discount_parsed as (
    select
        *,
        -- Extract discount percentage (first number before /)
        case
            when payment_terms_code like '%/%' then
                cast(split_part(payment_terms_code, '/', 1) as decimal(5,2))
            else 0.0
        end as early_payment_discount_pct,
        -- Extract discount days (number after / and before space or 'Net')
        case
            when payment_terms_code like '%/%' then
                cast(
                    {% if target.type == 'snowflake' %}
                    REGEXP_SUBSTR(payment_terms_code, '/(\\d+)', 1, 1, 'e', 1)
                    {% else %}
                    regexp_extract(payment_terms_code, '/(\d+)', 1)
                    {% endif %}
                    as integer
                )
            else null
        end as discount_days,
        -- Extract net days from payment terms
        case
            when payment_terms_code like '%Net%' then
                cast(
                    {% if target.type == 'snowflake' %}
                    REGEXP_SUBSTR(payment_terms_code, 'Net\\s*(\\d+)', 1, 1, 'e', 1)
                    {% else %}
                    regexp_extract(payment_terms_code, 'Net\s*(\d+)', 1)
                    {% endif %}
                    as integer
                )
            else null
        end as net_days
    from invoice_aging
),

-- Calculate discount deadline and opportunity status
invoice_discount as (
    select
        *,
        case
            when discount_days is not null then
                {% if target.type == 'snowflake' %}
                DATEADD(day, discount_days, invoice_date)
                {% else %}
                invoice_date + interval '1 day' * discount_days
                {% endif %}
            else null
        end as discount_deadline_raw
    from invoice_discount_parsed
),

invoice_discount_status as (
    select
        *,
        cast(discount_deadline_raw as date) as discount_deadline,
        case
            when early_payment_discount_pct = 0 or discount_deadline_raw is null then 'Not Applicable'
            when cast(discount_deadline_raw as date) >= analysis_date then 'Available'
            else 'Expired'
        end as discount_opportunity_status
    from invoice_discount
),

-- Calculate potential savings and annualized ROI
invoice_savings as (
    select
        *,
        case
            when discount_opportunity_status = 'Available' then
                round(amount_usd * (early_payment_discount_pct / 100.0), 2)
            else 0.0
        end as potential_savings_usd,
        -- Annualized ROI: (discount / (100 - discount)) * (365 / (net_days - discount_days)) * 100
        case
            when discount_opportunity_status = 'Available'
                 and net_days is not null
                 and discount_days is not null
                 and (net_days - discount_days) > 0 then
                round(
                    (early_payment_discount_pct / (100.0 - early_payment_discount_pct))
                    * (365.0 / (net_days - discount_days))
                    * 100.0,
                    2
                )
            else 0.0
        end as annualized_discount_roi
    from invoice_discount_status
),

-- Categorize discount ROI tier
invoice_roi_tier as (
    select
        *,
        case
            when annualized_discount_roi >= 36.0 then 'Exceptional'
            when annualized_discount_roi >= 18.0 then 'Good'
            when annualized_discount_roi > 0 then 'Marginal'
            else 'Not Applicable'
        end as discount_roi_tier
    from invoice_savings
),

-- Calculate days past optimal payment window
invoice_optimal as (
    select
        *,
        case
            -- If discount available, optimal is discount deadline
            when discount_opportunity_status = 'Available' and discount_deadline is not null then
                case
                    when analysis_date > discount_deadline then
                        cast(analysis_date - discount_deadline as integer)
                    else 0
                end
            -- If no discount, optimal is due date
            else
                case
                    when days_until_due < 0 then
                        abs(days_until_due)
                    else 0
                end
        end as days_past_optimal
    from invoice_roi_tier
),

-- Calculate supplier invoice concentration per supplier
supplier_concentration as (
    select
        supplier_id,
        sum(amount_usd) as supplier_total_usd
    from invoice_optimal
    group by supplier_id
),

invoice_with_concentration as (
    select
        inv.*,
        round(sc.supplier_total_usd / inv.total_amount_usd * 100, 2) as supplier_invoice_concentration
    from invoice_optimal inv
    inner join supplier_concentration sc on inv.supplier_id = sc.supplier_id
),

-- Calculate supplier risk score components
invoice_risk_components as (
    select
        *,
        -- Overdue weight (35% of score)
        case
            when days_until_due < -90 then 1.0
            when days_until_due < -60 then 0.75
            when days_until_due < -30 then 0.5
            when days_until_due <= 0 then 0.25
            else 0.0
        end as overdue_risk_weight,
        -- Concentration weight (25% of score) - cap at 50%, ensure non-negative
        greatest(0.0, least(supplier_invoice_concentration / 100.0, 0.5)) * 2.0 as concentration_weight,
        -- Rating inverse (20% of score) - lower rating = higher risk, clamp to 0-1
        greatest(0.0, least((5.0 - supplier_rating) / 4.0, 1.0)) as rating_risk_weight,
        -- Invoice age factor (20% of score) - older = higher risk, clamp to 0-1
        greatest(0.0, least(days_since_invoice / 180.0, 1.0)) as age_risk_weight
    from invoice_with_concentration
),

-- Calculate final supplier risk score
invoice_risk as (
    select
        *,
        round(
            (overdue_risk_weight * 35.0) +
            (concentration_weight * 25.0) +
            (rating_risk_weight * 20.0) +
            (age_risk_weight * 20.0),
            2
        ) as supplier_risk_score
    from invoice_risk_components
),

-- Categorize risk
invoice_risk_category as (
    select
        *,
        case
            when supplier_risk_score >= 75 then 'Critical Risk'
            when supplier_risk_score >= 50 then 'High Risk'
            when supplier_risk_score >= 25 then 'Medium Risk'
            else 'Low Risk'
        end as supplier_risk_category
    from invoice_risk
),

-- Calculate max amount for normalization in priority scoring
max_amounts as (
    select max(amount_usd) as max_amount_usd
    from invoice_risk_category
),

-- Calculate priority score components
invoice_priority_components as (
    select
        inv.*,
        m.max_amount_usd,
        -- Overdue weight (30 points max)
        case
            when inv.days_until_due < -90 then 1.0
            when inv.days_until_due < -60 then 0.8
            when inv.days_until_due < -30 then 0.6
            when inv.days_until_due <= 0 then 0.4
            else 0.0
        end as overdue_weight,
        -- Supplier risk weight (normalized to 0-1)
        inv.supplier_risk_score / 100.0 as risk_weight,
        -- Discount ROI weight
        case
            when inv.discount_roi_tier = 'Exceptional' then 1.0
            when inv.discount_roi_tier = 'Good' then 0.75
            when inv.discount_roi_tier = 'Marginal' then 0.5
            else 0.0
        end as discount_weight,
        -- Amount weight (normalized)
        inv.amount_usd / m.max_amount_usd as amount_weight,
        -- Supplier rating weight (normalized to 0-1)
        inv.supplier_rating / 5.0 as supplier_rating_weight
    from invoice_risk_category inv
    cross join max_amounts m
),

-- Calculate final priority score
invoice_priority as (
    select
        *,
        round(
            (overdue_weight * 30.0) +
            (risk_weight * 25.0) +
            (discount_weight * 20.0) +
            (amount_weight * 15.0) +
            (supplier_rating_weight * 10.0),
            2
        ) as payment_priority_score
    from invoice_priority_components
),

-- Calculate priority rank and tier
invoice_ranked as (
    select
        *,
        row_number() over (
            order by payment_priority_score desc, due_date asc, invoice_id asc
        ) as priority_rank
    from invoice_priority
),

invoice_tiered as (
    select
        *,
        ntile(4) over (order by priority_rank) as tier_quartile
    from invoice_ranked
),

invoice_tier_assigned as (
    select
        *,
        case tier_quartile
            when 1 then 'Critical'
            when 2 then 'High'
            when 3 then 'Medium'
            when 4 then 'Low'
        end as priority_tier
    from invoice_tiered
),

-- Determine payment strategy
invoice_strategy as (
    select
        *,
        case
            -- Take discount if Available and ROI is good
            when discount_opportunity_status = 'Available'
                 and discount_roi_tier in ('Exceptional', 'Good') then 'Take Discount'
            -- Immediate payment for overdue high-risk
            when aging_bucket like '%Overdue%'
                 and supplier_risk_category in ('High Risk', 'Critical Risk') then 'Immediate Payment'
            -- Defer if low risk and plenty of time
            when aging_bucket = 'Not Yet Due'
                 and supplier_risk_category = 'Low Risk'
                 and days_until_due > 14 then 'Defer Payment'
            -- Default: pay on due date
            else 'Pay On Due Date'
        end as payment_strategy
    from invoice_tier_assigned
),

-- Calculate recommended payment date based on strategy
invoice_recommended as (
    select
        *,
        case
            when payment_strategy = 'Take Discount' and discount_deadline is not null then
                discount_deadline
            when payment_strategy = 'Immediate Payment' then
                analysis_date
            else
                due_date
        end as recommended_payment_date
    from invoice_strategy
),

-- Calculate cash outflow week and working capital metrics
invoice_cashflow as (
    select
        *,
        cast(weekofyear(recommended_payment_date) as integer) as cash_outflow_week,
        cast(recommended_payment_date - invoice_date as integer) as working_capital_days
    from invoice_recommended
),

-- Calculate weekly outflow totals
weekly_totals as (
    select
        cash_outflow_week,
        round(sum(amount_usd), 2) as weekly_outflow_usd
    from invoice_cashflow
    group by cash_outflow_week
),

-- Join weekly totals back
invoice_with_weekly as (
    select
        inv.*,
        wt.weekly_outflow_usd
    from invoice_cashflow inv
    inner join weekly_totals wt on inv.cash_outflow_week = wt.cash_outflow_week
),

-- Calculate float benefit and cumulative outflow
final_output as (
    select
        invoice_id,
        supplier_id,
        supplier_name,
        supplier_rating,
        cast(invoice_date as date) as invoice_date,
        cast(due_date as date) as due_date,
        invoice_amount,
        currency_code,
        amount_usd,
        days_until_due,
        aging_bucket,
        days_past_optimal,
        payment_terms_code,
        early_payment_discount_pct,
        discount_deadline,
        potential_savings_usd,
        discount_opportunity_status,
        annualized_discount_roi,
        discount_roi_tier,
        payment_priority_score,
        priority_rank,
        priority_tier,
        supplier_risk_score,
        supplier_risk_category,
        supplier_invoice_concentration,
        cast(recommended_payment_date as date) as recommended_payment_date,
        payment_strategy,
        cash_outflow_week,
        round(
            sum(amount_usd) over (
                order by recommended_payment_date, invoice_id
                rows between unbounded preceding and current row
            ),
            2
        ) as cumulative_outflow_usd,
        weekly_outflow_usd,
        working_capital_days,
        round(amount_usd * (0.05 / 365.0) * working_capital_days, 2) as float_benefit_usd
    from invoice_with_weekly
)

select * from final_output
EOF

# Run dbt to build the model
echo "Running dbt to build supplier_payment_optimization model..."
dbt run --select +supplier_payment_optimization


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
    'supplier_payment_optimization'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "' ~ db ~ '"."main"."' ~ t ~ '" AS SELECT * FROM "' ~ db ~ '".MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution completed successfully!"
