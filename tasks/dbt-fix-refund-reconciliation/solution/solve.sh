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

MODEL_PATH="$DBT_PROJECT_DIR/models/marts/sales/rpt_return_reconciliation.sql"

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

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

cat > "$MODEL_PATH" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'sales', 'returns']
    )
}}

with return_lines_agg as (
    select
        rl.return_id,
        count(*) as return_line_count,
        sum(rl.REFUND_AMOUNT) as total_refund_amount
    from {{ ref('stg_orders__return_lines') }} rl
    group by rl.return_id
),

returns_base as (
    select
        r.return_id,
        r.return_number,
        r.order_id,
        r.customer_id,
        r.return_type,
        r.refund_method,
        r.status,
        r.REFUND_AMOUNT as total_return_amount,
        coalesce(rla.total_refund_amount, 0) as total_refund_amount_lines,
        coalesce(rla.return_line_count, 0) as return_line_count,
        r.REQUESTED_AT as requested_at,
        r.RECEIVED_AT as received_at,
        r.PROCESSED_AT as processed_at
    from {{ ref('stg_orders__returns') }} r
    left join return_lines_agg rla on r.return_id = rla.return_id
    where r.return_id is not null
),

with_timing as (
    select
        *,
        DATEDIFF('day', requested_at, received_at) as days_to_receive,
        DATEDIFF('day', received_at, processed_at) as days_to_process,
        DATEDIFF('day', requested_at, processed_at) as total_processing_days,
        total_refund_amount_lines / NULLIF(total_return_amount, 0) as refund_completion_rate,
        1.0 / NULLIF(DATEDIFF('day', requested_at, processed_at), 0) as processing_efficiency
    from returns_base
),

with_percentiles as (
    select
        wt.*,
        p.processing_slowness_percentile
    from with_timing wt
    left join (
        select
            return_id,
            PERCENT_RANK() OVER (ORDER BY total_processing_days DESC) as processing_slowness_percentile
        from with_timing
        where total_processing_days is not null
    ) p on wt.return_id = p.return_id
),

final as (
    select
        return_id,
        return_number,
        order_id,
        customer_id,
        return_type,
        refund_method,
        status,
        total_return_amount,
        total_refund_amount_lines as total_refund_amount,
        return_line_count,
        requested_at,
        received_at,
        processed_at,
        days_to_receive,
        days_to_process,
        total_processing_days,
        refund_completion_rate,
        processing_efficiency,
        case
            when processing_slowness_percentile <= 0.25
                 and coalesce(total_processing_days, 0) > 10
                then 'critical_delay'
            when processing_slowness_percentile <= 0.50
                 or coalesce(refund_completion_rate, 0) < 0.80
                then 'needs_improvement'
            when coalesce(refund_completion_rate, 0) >= 0.85
                 and coalesce(total_processing_days, 999) <= 7
                then 'acceptable'
            when processing_slowness_percentile >= 0.75
                 and coalesce(refund_completion_rate, 0) >= 0.90
                then 'efficient'
            else 'acceptable'
        end as refund_velocity_tier
    from with_percentiles
)

select * from final
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps
dbt run -s rpt_return_reconciliation
