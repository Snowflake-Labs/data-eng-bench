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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/marketing/rpt_channel_roi_payback_monthly.sql"
YML_PATH="$DBT_PROJECT_DIR/models/marts/marketing/rpt_channel_roi_payback_monthly.yml"

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

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

cat > "$MODEL_PATH" << '_EOF_'
{{ config(materialized='view') }}
with marketing_monthly as (
    select
        date_trunc('month', d.full_date) as month_start,
        ms.channel_key,
        sum(ms.impressions) as impressions,
        sum(ms.clicks) as clicks,
        sum(ms.conversions) as conversions,
        sum(ms.spend_amount) as spend_amount,
        sum(ms.revenue_attributed) as revenue_attributed,
        cast(sum(ms.clicks) as double) / nullif(sum(ms.impressions), 0) as ctr,
        cast(sum(ms.conversions) as double) / nullif(sum(ms.clicks), 0) as conversion_rate,
        cast(sum(ms.spend_amount) as double) / nullif(sum(ms.conversions), 0) as cpa,
        cast(sum(ms.revenue_attributed) as double) / nullif(sum(ms.spend_amount), 0) as roas
    from {{ ref('stg_fact_marketing_spend') }} ms
    join {{ ref('stg_analytics__dim_date') }} d
        on ms.date_key = d.date_key
    group by 1, 2
),

sales_facts as (
    select
        customer_key,
        channel_key,
        date_key,
        order_id,
        total_amount,
        profit_amount
    from {{ ref('stg_analytics__fact_sales') }}
),

first_purchase as (
    select
        customer_key,
        min(date_key) as first_date_key
    from sales_facts
    group by 1
),

first_purchase_detail as (
    select
        fp.customer_key,
        fp.first_date_key,
        min(sf.channel_key) as first_channel_key,
        d.full_date as first_purchase_date
    from first_purchase fp
    join sales_facts sf
        on fp.customer_key = sf.customer_key
       and fp.first_date_key = sf.date_key
    join {{ ref('stg_analytics__dim_date') }} d
        on fp.first_date_key = d.date_key
    group by 1, 2, 4
),

new_customer_monthly as (
    select
        date_trunc('month', fpd.first_purchase_date) as month_start,
        fpd.first_channel_key as channel_key,
        coalesce(dc.segment_name, 'Unknown') as segment_name,
        coalesce(dc.tier_name, 'Unknown') as tier_name,
        count(distinct fpd.customer_key) as new_customers
    from first_purchase_detail fpd
    join {{ ref('stg_analytics__dim_customer') }} dc
        on fpd.customer_key = dc.customer_key
    group by 1, 2, 3, 4
),

new_customer_totals as (
    select
        month_start,
        channel_key,
        sum(new_customers) as total_new_customers
    from new_customer_monthly
    group by 1, 2
),

segment_mix as (
    select
        ncm.month_start,
        ncm.channel_key,
        ncm.segment_name,
        ncm.tier_name,
        ncm.new_customers,
        nct.total_new_customers,
        cast(ncm.new_customers as double) / nullif(nct.total_new_customers, 0) as new_customer_share
    from new_customer_monthly ncm
    join new_customer_totals nct
        on ncm.month_start = nct.month_start
       and ncm.channel_key = nct.channel_key
),

ltv_90d as (
    select
        date_trunc('month', fpd.first_purchase_date) as month_start,
        fpd.first_channel_key as channel_key,
        coalesce(dc.segment_name, 'Unknown') as segment_name,
        coalesce(dc.tier_name, 'Unknown') as tier_name,
        sum(sf.total_amount) as revenue_90d,
        sum(sf.profit_amount) as profit_90d
    from first_purchase_detail fpd
    join sales_facts sf
        on sf.customer_key = fpd.customer_key
    join {{ ref('stg_analytics__dim_date') }} d
        on sf.date_key = d.date_key
    join {{ ref('stg_analytics__dim_customer') }} dc
        on fpd.customer_key = dc.customer_key
    where d.full_date >= fpd.first_purchase_date
      and d.full_date < fpd.first_purchase_date + interval '90 day'
    group by 1, 2, 3, 4
),

sales_monthly as (
    select
        date_trunc('month', d.full_date) as month_start,
        sf.channel_key,
        sum(sf.total_amount) as sales_revenue,
        sum(sf.profit_amount) as sales_profit,
        count(distinct sf.order_id) as order_count
    from sales_facts sf
    join {{ ref('stg_analytics__dim_date') }} d
        on sf.date_key = d.date_key
    group by 1, 2
)

select
    m.month_start,
    m.channel_key,
    ch.channel_name,
    ch.channel_type,
    smix.segment_name,
    smix.tier_name,
    m.impressions,
    m.clicks,
    m.conversions,
    m.ctr,
    m.conversion_rate,
    m.spend_amount,
    m.revenue_attributed,
    m.roas,
    sm.sales_revenue,
    sm.sales_profit,
    sm.order_count,
    cast(sm.order_count as double) / nullif(m.conversions, 0) as order_conversion_rate,
    smix.new_customers,
    smix.total_new_customers,
    smix.new_customer_share,
    cast(m.spend_amount as double) / nullif(smix.total_new_customers, 0) as blended_cac,
    cast(ltv.revenue_90d as double) / nullif(smix.new_customers, 0) as ltv_90d_revenue_per_customer,
    cast(ltv.profit_90d as double) / nullif(smix.new_customers, 0) as ltv_90d_profit_per_customer,
    cast(ltv.profit_90d as double) / nullif(cast(m.spend_amount as double) * smix.new_customer_share, 0) as payback_90d_profit_ratio
from marketing_monthly m
left join {{ ref('stg_analytics__dim_channel') }} ch
    on m.channel_key = ch.channel_key
left join sales_monthly sm
    on m.month_start = sm.month_start
   and m.channel_key = sm.channel_key
left join segment_mix smix
    on m.month_start = smix.month_start
   and m.channel_key = smix.channel_key
left join ltv_90d ltv
    on smix.month_start = ltv.month_start
   and smix.channel_key = ltv.channel_key
   and smix.segment_name = ltv.segment_name
   and smix.tier_name = ltv.tier_name
_EOF_

cat > "$YML_PATH" << '_EOF_'
version: 2

models:
  - name: rpt_channel_roi_payback_monthly
    columns:
      - name: month_start
        tests:
          - not_null
      - name: channel_key
        tests:
          - not_null
      - name: impressions
        tests:
          - not_null
      - name: clicks
        tests:
          - not_null
      - name: conversions
        tests:
          - not_null
      - name: spend_amount
        tests:
          - not_null
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - month_start
            - channel_key
            - segment_name
            - tier_name
_EOF_

cd "$DBT_PROJECT_DIR"

dbt deps
dbt run --select rpt_channel_roi_payback_monthly --profiles-dir .
dbt test --select rpt_channel_roi_payback_monthly --profiles-dir .

echo "Solution complete!"
