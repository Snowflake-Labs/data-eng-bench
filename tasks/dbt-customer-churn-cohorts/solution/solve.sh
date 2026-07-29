#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
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

# Prepare dbt project structure
mkdir -p models/intermediate models/marts seeds

# ============ INTERMEDIATE MODELS ============

cat > models/intermediate/int_analytics__fact_sales.sql << 'INNEREOF'
{{
    config(
        materialized='view'
    )
}}
with sales as (
    select * from {{ ref('stg_analytics__fact_sales') }}
),
customers as (
    select * from {{ ref('stg_analytics__dim_customer') }}
),
dates as (
    select * from {{ ref('stg_analytics__dim_date') }}
)
select
    sales.order_id as transaction_id,
    customers.customer_id as customer_id,
    dates.full_date as transaction_date,
    sales.total_amount as amount,
    cast(null as varchar) as product_category
from sales
left join customers on sales.customer_key = customers.customer_key
left join dates on sales.date_key = dates.date_key
INNEREOF

cat > models/intermediate/int_customer__customers.sql << 'INNEREOF'
{{
    config(
        materialized='view'
    )
}}
select
     customer_id,
     acquisition_date as signup_date,
     customer_segment_snapshot as customer_segment,
     legacy_region_code as region
from {{ ref('stg_customer__customers') }}
INNEREOF

# ============ MARTS MODELS ============

# Customer Cohorts - assigns customers to cohorts based on first transaction
cat > models/marts/customer_cohorts.sql << 'INNEREOF'
/*
Customer Cohort Assignment
*/
{{
    config(
        materialized='view'
    )
}}

with first_transaction as (
    select
        customer_id,
        min(transaction_date) as first_transaction_date,
        min(transaction_id) as first_txn_id
    from {{ ref('int_analytics__fact_sales') }}
    group by customer_id
),

first_transaction_details as (
    select
        t.customer_id,
        t.transaction_date as first_transaction_date,
        t.amount as first_transaction_amount
    from {{ ref('int_analytics__fact_sales') }} t
    inner join first_transaction ft
        on t.customer_id = ft.customer_id
        and t.transaction_date = ft.first_transaction_date
        and t.transaction_id = ft.first_txn_id
),

customer_info as (
    select
        customer_id,
        signup_date,
        region
    from {{ ref('int_customer__customers') }}
)

select
    ftd.customer_id,
    {% if target.type == 'snowflake' %}
    TO_CHAR(ftd.first_transaction_date, 'YYYY-MM') as cohort_month,
    {% else %}
    strftime(ftd.first_transaction_date, '%Y-%m') as cohort_month,
    {% endif %}
    ftd.first_transaction_date,
    ftd.first_transaction_amount,
    cast(
        case
            when ci.signup_date is null then 0
            {% if target.type == 'snowflake' %}
            else greatest(0, DATEDIFF('day', ci.signup_date, ftd.first_transaction_date))
            {% else %}
            else greatest(0, cast(ftd.first_transaction_date - ci.signup_date as integer))
            {% endif %}
        end as integer
    ) as signup_to_first_purchase_days,
    case ci.region
        when 'NORTH' then 'Online'
        when 'SOUTH' then 'Retail'
        when 'EAST' then 'Partner'
        when 'WEST' then 'Direct'
        else 'Unknown'
    end as acquisition_channel
from first_transaction_details ftd
left join customer_info ci on ftd.customer_id = ci.customer_id
order by ftd.customer_id
INNEREOF

# Cohort Retention - calculates retention metrics per cohort and period
cat > models/marts/cohort_retention.sql << 'INNEREOF'
/*
Cohort Retention Analysis
*/
{{
    config(
        materialized='view'
    )
}}

with customer_cohorts as (
    select
        customer_id,
        {% if target.type == 'snowflake' %}
        TO_CHAR(min(transaction_date), 'YYYY-MM') as cohort_month,
        {% else %}
        strftime(min(transaction_date), '%Y-%m') as cohort_month,
        {% endif %}
        min(transaction_date) as first_txn_date
    from {{ ref('int_analytics__fact_sales') }}
    group by customer_id
),

monthly_activity as (
    select distinct
        t.customer_id,
        cc.cohort_month,
        cc.first_txn_date,
        {% if target.type == 'snowflake' %}
        TO_CHAR(t.transaction_date, 'YYYY-MM') as activity_month,
        {% else %}
        strftime(t.transaction_date, '%Y-%m') as activity_month,
        {% endif %}
        cast(
            (extract(year from t.transaction_date) - extract(year from cc.first_txn_date)) * 12 +
            (extract(month from t.transaction_date) - extract(month from cc.first_txn_date))
        as integer) as period_number
    from {{ ref('int_analytics__fact_sales') }} t
    inner join customer_cohorts cc on t.customer_id = cc.customer_id
),

cohort_sizes as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_cohorts
    group by cohort_month
),

period_activity as (
    select
        cohort_month,
        period_number,
        activity_month as period_month,
        count(distinct customer_id) as active_customers
    from monthly_activity
    group by cohort_month, period_number, activity_month
),

retained_calc as (
    select
        m1.cohort_month,
        m1.period_number,
        count(distinct m1.customer_id) as retained_customers
    from monthly_activity m1
    inner join monthly_activity m2
        on m1.customer_id = m2.customer_id
        and m1.cohort_month = m2.cohort_month
        and m1.period_number = m2.period_number + 1
    group by m1.cohort_month, m1.period_number
),

revenue_by_period as (
    select
        cc.cohort_month,
        cast(
            (extract(year from t.transaction_date) - extract(year from cc.first_txn_date)) * 12 +
            (extract(month from t.transaction_date) - extract(month from cc.first_txn_date))
        as integer) as period_number,
        sum(t.amount) as period_revenue
    from {{ ref('int_analytics__fact_sales') }} t
    inner join customer_cohorts cc on t.customer_id = cc.customer_id
    group by cc.cohort_month, period_number
),

combined as (
    select
        pa.cohort_month,
        cast(pa.period_number as integer) as period_number,
        pa.period_month,
        cs.cohort_size,
        pa.active_customers,
        -- For period 0, retained = active; otherwise use calculated value
        case
            when pa.period_number = 0 then pa.active_customers
            else coalesce(rc.retained_customers, 0)
        end as retained_customers,
        {% if target.type == 'snowflake' %}
        round(cast(pa.active_customers as float) / cast(cs.cohort_size as float), 4) as retention_rate,
        {% else %}
        round(cast(pa.active_customers as double) / cast(cs.cohort_size as double), 4) as retention_rate,
        {% endif %}
        coalesce(r.period_revenue, 0) as period_revenue
    from period_activity pa
    inner join cohort_sizes cs on pa.cohort_month = cs.cohort_month
    left join retained_calc rc
        on pa.cohort_month = rc.cohort_month
        and pa.period_number = rc.period_number
    left join revenue_by_period r
        on pa.cohort_month = r.cohort_month
        and pa.period_number = r.period_number
),

final as (
    select
        cohort_month,
        period_number,
        period_month,
        cohort_size,
        active_customers,
        retained_customers,
        retention_rate,
        period_revenue,
        sum(period_revenue) over (
            partition by cohort_month
            order by period_number
            rows between unbounded preceding and current row
        ) as cumulative_revenue
    from combined
)

select * from final
order by cohort_month, period_number
INNEREOF

# Customer CLV - calculates customer lifetime value with churn scoring
cat > models/marts/customer_clv.sql << 'INNEREOF'
/*
Customer Lifetime Value with Churn Scoring
*/
{{
    config(
        materialized='view'
    )
}}

{% set ref_date = var('reference_date', '2024-12-31') %}

with customer_stats as (
    select
        customer_id,
        {% if target.type == 'snowflake' %}
        TO_CHAR(min(transaction_date), 'YYYY-MM') as cohort_month,
        {% else %}
        strftime(min(transaction_date), '%Y-%m') as cohort_month,
        {% endif %}
        count(*) as total_transactions,
        sum(amount) as total_revenue,
        round(avg(amount), 2) as avg_transaction_value,
        min(transaction_date) as first_txn,
        max(transaction_date) as last_txn
    from {{ ref('int_analytics__fact_sales') }}
    group by customer_id
),

lifespan_calc as (
    select
        customer_id,
        cohort_month,
        total_transactions,
        total_revenue,
        avg_transaction_value,
        first_txn,
        last_txn,
        -- Lifespan in months (minimum 1)
        cast(greatest(1,
            (extract(year from last_txn) - extract(year from first_txn)) * 12 +
            (extract(month from last_txn) - extract(month from first_txn)) + 1
        ) as integer) as customer_lifespan_months,
        -- Months since last transaction to reference date
        cast(
            (extract(year from cast('{{ ref_date }}' as date)) - extract(year from last_txn)) * 12 +
            (extract(month from cast('{{ ref_date }}' as date)) - extract(month from last_txn))
        as integer) as months_since_last_transaction
    from customer_stats
),

churn_factors as (
    select
        *,
        round(total_revenue / customer_lifespan_months, 2) as monthly_revenue_rate,
        -- Base score
        {% if target.type == 'snowflake' %}
        cast(months_since_last_transaction as float) / 12.0 as base_score,
        {% else %}
        cast(months_since_last_transaction as double) / 12.0 as base_score,
        {% endif %}
        -- Frequency factor
        case
            when total_transactions >= 10 then 0.7
            when total_transactions >= 5 then 0.85
            when total_transactions >= 2 then 1.0
            else 1.3
        end as frequency_factor,
        -- Recency factor
        case
            when months_since_last_transaction <= 1 then 0.5
            when months_since_last_transaction <= 3 then 0.8
            when months_since_last_transaction <= 6 then 1.0
            else 1.2
        end as recency_factor
    from lifespan_calc
),

clv_calc as (
    select
        customer_id,
        cohort_month,
        total_transactions,
        total_revenue,
        avg_transaction_value,
        customer_lifespan_months,
        monthly_revenue_rate,
        months_since_last_transaction,
        round(least(1.0, base_score * frequency_factor * recency_factor), 2) as churn_probability
    from churn_factors
),

final as (
    select
        customer_id,
        cohort_month,
        total_transactions,
        total_revenue,
        avg_transaction_value,
        customer_lifespan_months,
        monthly_revenue_rate,
        months_since_last_transaction,
        churn_probability,
        round(monthly_revenue_rate * 12 * (1 - churn_probability), 2) as predicted_clv_12m
    from clv_calc
)

select
    customer_id,
    cohort_month,
    total_transactions,
    total_revenue,
    avg_transaction_value,
    customer_lifespan_months,
    monthly_revenue_rate,
    months_since_last_transaction,
    churn_probability,
    predicted_clv_12m,
    case
        when predicted_clv_12m >= 1000 then 'Platinum'
        when predicted_clv_12m >= 500 then 'Gold'
        when predicted_clv_12m >= 100 then 'Silver'
        else 'Bronze'
    end as customer_tier
from final
order by customer_id
INNEREOF

# Run dbt
dbt deps
dbt run --select \
    stg_analytics__fact_sales \
    stg_analytics__dim_customer \
    stg_analytics__dim_date \
    stg_customer__customers \
    int_analytics__fact_sales \
    int_customer__customers \
    customer_cohorts \
    cohort_retention \
    customer_clv
