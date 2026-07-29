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
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi
echo "Using dbt project: $DBT_PROJECT_DIR"

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: main
PROFILES
    echo "Configured DuckDB profile"
fi

# Create the sales marts directory if it doesn't exist
mkdir -p "$DBT_PROJECT_DIR/models/marts/sales"

cat > "$DBT_PROJECT_DIR/models/marts/sales/rpt_payment_analytics.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'sales', 'payments']
    )
}}

with orders as (
    select
        ORDER_ID as order_id
    from {{ ref('int_sales__orders_enriched') }}
    where UPPER(status) NOT IN ('CANCELLED', 'C')
      and ORDER_ID is not null
),

payments as (
    select
        p.payment_id,
        p.order_id,
        p.payment_method,
        p.AMOUNT as amount,
        p.status
    from {{ ref('stg_orders__order_payments') }} p
    inner join orders o on p.order_id = o.order_id
    where p.payment_method is not null
),

-- Aggregate metrics per payment method
payment_metrics as (
    select
        payment_method,
        count(*) as total_transactions,
        count(distinct order_id) as total_orders,
        sum(amount) as total_amount,
        sum(case when status IN ('COMPLETED', 'CAPTURED') then amount else 0 end) as successful_amount,
        count(case when status = 'FAILED' then 1 end) as failed_transactions,
        count(case when status IN ('PENDING', 'AUTHORIZED') then 1 end) as pending_transactions,
        count(case when status IN ('COMPLETED', 'CAPTURED') then 1 end) as successful_transactions
    from payments
    group by payment_method
),

-- Calculate base rates and assign provider type
payment_rates as (
    select
        payment_method,
        total_transactions,
        total_orders,
        total_amount,
        successful_amount,
        failed_transactions,
        pending_transactions,

        -- Safe division for rates
        coalesce(cast(successful_transactions as double) / NULLIF(total_transactions, 0), 0) as success_rate,
        coalesce(cast(total_amount as double) / NULLIF(total_transactions, 0), 0) as avg_transaction_amount,
        coalesce(cast(failed_transactions as double) / NULLIF(total_transactions, 0), 0) as failure_rate,

        -- Determine provider type based on payment method name
        case
            when UPPER(payment_method) LIKE '%CREDIT%'
                 OR UPPER(payment_method) LIKE '%DEBIT%'
                 OR UPPER(payment_method) LIKE '%CARD%'
                 OR UPPER(payment_method) LIKE '%VISA%'
                 OR UPPER(payment_method) LIKE '%MASTERCARD%'
                 OR UPPER(payment_method) LIKE '%AMEX%'
                 OR UPPER(payment_method) LIKE '%DISCOVER%' then 'CARD'
            when UPPER(payment_method) LIKE '%PAYPAL%'
                 OR UPPER(payment_method) LIKE '%VENMO%'
                 OR UPPER(payment_method) LIKE '%APPLE%'
                 OR UPPER(payment_method) LIKE '%GOOGLE%'
                 OR UPPER(payment_method) LIKE '%WALLET%' then 'DIGITAL'
            when UPPER(payment_method) LIKE '%BANK%'
                 OR UPPER(payment_method) LIKE '%ACH%'
                 OR UPPER(payment_method) LIKE '%WIRE%'
                 OR UPPER(payment_method) LIKE '%TRANSFER%' then 'BANK'
            else 'OTHER'
        end as provider_type

    from payment_metrics
),

-- Calculate peer comparison metrics (partitioned by provider_type)
with_peer_metrics as (
    select
        *,
        -- Rank by success rate within provider_type (1 = best, descending order)
        DENSE_RANK() OVER (PARTITION BY provider_type ORDER BY success_rate DESC) as provider_success_rank,

        -- Total payment methods in provider_type
        COUNT(*) OVER (PARTITION BY provider_type) as provider_method_count,

        -- Provider average success rate
        AVG(success_rate) OVER (PARTITION BY provider_type) as provider_avg_success,

        -- Volume percentile within provider_type
        PERCENT_RANK() OVER (PARTITION BY provider_type ORDER BY total_transactions) as provider_volume_percentile,

        -- Reliability score percentile within provider (for tier calculation)
        PERCENT_RANK() OVER (PARTITION BY provider_type ORDER BY
            (success_rate * 0.40 + (1 - failure_rate) * 0.30 +
             LEAST(cast(total_transactions as double) / 1000.0, 1.0) * 0.15 +
             LEAST(avg_transaction_amount / 500.0, 1.0) * 0.15)
        ) as reliability_percentile_in_provider

    from payment_rates
),

-- Calculate reliability score and above_provider_avg
with_reliability as (
    select
        *,
        -- Above provider average success (1/0 boolean)
        case when success_rate > provider_avg_success then 1 else 0 end as above_provider_avg_success,

        -- Reliability score: weighted composite (0-100 scale)
        -- Weights: success_rate 40%, inverse failure_rate 30%, volume 15%, avg_amount 15%
        LEAST(100, GREATEST(0,
            (success_rate * 0.40 +
             (1 - failure_rate) * 0.30 +
             LEAST(cast(total_transactions as double) / 1000.0, 1.0) * 0.15 +
             LEAST(avg_transaction_amount / 500.0, 1.0) * 0.15
            ) * 100
        )) as reliability_score

    from with_peer_metrics
),

-- Assign payment health tiers using waterfall logic
final as (
    select
        payment_method,
        provider_type,
        total_transactions,
        total_orders,
        total_amount,
        successful_amount,
        failed_transactions,
        pending_transactions,
        success_rate,
        avg_transaction_amount,
        failure_rate,
        provider_success_rank,
        provider_method_count,
        above_provider_avg_success,
        provider_volume_percentile,
        reliability_score,

        -- Waterfall tier logic (check worst first)
        case
            -- critical: failure_rate >= 15% OR success_rate < 70%
            when failure_rate >= 0.15 or success_rate < 0.70 then 'critical'
            -- problematic: failure_rate >= 8% OR below provider average success
            when failure_rate >= 0.08 or above_provider_avg_success = 0 then 'problematic'
            -- concerning: failure_rate >= 3% OR success_rate < 90%
            when failure_rate >= 0.03 or success_rate < 0.90 then 'concerning'
            -- excellent: Top 25% by reliability_score within provider AND failure_rate < 2%
            when reliability_percentile_in_provider >= 0.75 and failure_rate < 0.02 then 'excellent'
            -- good: Above provider average AND reliability_score >= 60
            when above_provider_avg_success = 1 and reliability_score >= 60 then 'good'
            -- Fallback to concerning
            else 'concerning'
        end as payment_health_tier

    from with_reliability
)

select * from final
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps
dbt run -s rpt_payment_analytics
