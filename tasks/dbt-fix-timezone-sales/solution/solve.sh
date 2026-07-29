#!/bin/bash
set -e

echo "=========================================="
echo "Applying Fix for Timezone Bug"
echo "=========================================="

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

MODEL_PATH="$DBT_PROJECT_DIR/models/intermediate/sales/int_sales__orders_enriched.sql"

echo "Creating fixed int_sales__orders_enriched.sql..."

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

cat > "$MODEL_PATH" <<'SQL'
{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

{% if target.type == 'snowflake' %}

{% set clean_currency %}
TRY_TO_DECIMAL(REGEXP_REPLACE(CAST(%s AS VARCHAR), '[^0-9.-]', ''), 18, 2)
{% endset %}

{% set parse_timestamp %}
CASE
    WHEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'YYYY-MM-DD HH24:MI:SS') IS NOT NULL THEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'YYYY-MM-DD HH24:MI:SS')
    WHEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'YYYY-MM-DD') IS NOT NULL THEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'YYYY-MM-DD')
    WHEN REGEXP_LIKE(CAST(%s AS VARCHAR), '^[0-9]{8}$') THEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'YYYYMMDD')
    WHEN REGEXP_LIKE(CAST(%s AS VARCHAR), '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4} [0-9]{1,2}:[0-9]{2}') THEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'MM/DD/YYYY HH24:MI:SS')
    WHEN REGEXP_LIKE(CAST(%s AS VARCHAR), '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$') THEN TRY_TO_TIMESTAMP(CAST(%s AS VARCHAR), 'MM/DD/YYYY')
    WHEN TRY_TO_NUMBER(CAST(%s AS VARCHAR), 38, 6) IS NOT NULL THEN TO_TIMESTAMP_NTZ(TRY_TO_NUMBER(CAST(%s AS VARCHAR), 38, 6))
    ELSE NULL
END
{% endset %}

{% else %}

{% set clean_currency = "regexp_replace(CAST(%s AS VARCHAR), '[^0-9.-]', '', 'g')::decimal(18,2)" %}

{% set parse_timestamp %}
CASE
    WHEN TRY_CAST(%s AS TIMESTAMP) IS NOT NULL THEN TRY_CAST(%s AS TIMESTAMP)
    WHEN CAST(%s AS VARCHAR) ~ '^[0-9]{4}[0-9]{2}[0-9]{2}$' THEN TRY_CAST(strptime(CAST(%s AS VARCHAR), '%%Y%%m%%d') AS TIMESTAMP)
    WHEN CAST(%s AS VARCHAR) ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4} [0-9]{1,2}:[0-9]{2}' THEN TRY_CAST(strptime(CAST(%s AS VARCHAR), '%%m/%%d/%%Y %%H:%%M:%%S') AS TIMESTAMP)
    WHEN CAST(%s AS VARCHAR) ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}' THEN TRY_CAST(strptime(CAST(%s AS VARCHAR), '%%m/%%d/%%Y') AS TIMESTAMP)
    WHEN TRY_CAST(%s AS DOUBLE) IS NOT NULL THEN to_timestamp(TRY_CAST(%s AS DOUBLE))
    ELSE NULL
END
{% endset %}

{% endif %}

with sap_orders as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        'SAP' as source_system,
        currency_code,
        exchange_rate,
        {{ clean_currency % 'subtotal' }} as subtotal,
        {{ clean_currency % 'discount_total' }} as discount_total,
        {{ clean_currency % 'shipping_total' }} as shipping_total,
        {{ clean_currency % 'tax_total' }} as tax_total,
        {{ clean_currency % 'grand_total' }} as grand_total,
        status,
        payment_status,
        fulfillment_status,
{% if target.type == 'snowflake' %}
        {{ parse_timestamp % ('ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at') }} as ordered_at,
        {{ parse_timestamp % ('shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at') }} as shipped_at,
        {{ parse_timestamp % ('delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at') }} as delivered_at,
        {{ parse_timestamp % ('cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at') }} as cancelled_at
{% else %}
        {{ parse_timestamp % ('ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at') }} as ordered_at,
        {{ parse_timestamp % ('shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at') }} as shipped_at,
        {{ parse_timestamp % ('delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at') }} as delivered_at,
        {{ parse_timestamp % ('cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at') }} as cancelled_at
{% endif %}
    from {{ ref('stg_sap__vbak') }}

),

pos_orders as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        'POS' as source_system,
        currency_code,
        exchange_rate,
        {{ clean_currency % 'subtotal' }} as subtotal,
        {{ clean_currency % 'discount_total' }} as discount_total,
        {{ clean_currency % 'shipping_total' }} as shipping_total,
        {{ clean_currency % 'tax_total' }} as tax_total,
        {{ clean_currency % 'grand_total' }} as grand_total,
        status,
        payment_status,
        fulfillment_status,
{% if target.type == 'snowflake' %}
        DATEADD('hour', 5, {{ parse_timestamp % ('ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at') }}) as ordered_at,
        DATEADD('hour', 5, {{ parse_timestamp % ('shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at') }}) as shipped_at,
        DATEADD('hour', 5, {{ parse_timestamp % ('delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at') }}) as delivered_at,
        DATEADD('hour', 5, {{ parse_timestamp % ('cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at') }}) as cancelled_at
{% else %}
        {{ parse_timestamp % ('ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at') }} + INTERVAL '5 hours' as ordered_at,
        {{ parse_timestamp % ('shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at') }} + INTERVAL '5 hours' as shipped_at,
        {{ parse_timestamp % ('delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at') }} + INTERVAL '5 hours' as delivered_at,
        {{ parse_timestamp % ('cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at') }} + INTERVAL '5 hours' as cancelled_at
{% endif %}
    from {{ ref('stg_pos__transactions') }}

),

all_orders as (

    select * from sap_orders
    union all
    select * from pos_orders

),

final as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        source_system,
        currency_code,
        exchange_rate,

        -- Order amounts
        subtotal,
        discount_total,
        shipping_total,
        tax_total,
        grand_total,

        -- Calculated fields
        (subtotal - discount_total) as net_subtotal,
        case
            when subtotal > 0 then CAST(discount_total AS DOUBLE) / CAST(subtotal AS DOUBLE)
            else 0
        end as discount_rate,

        -- Status fields
        status,
        payment_status,
        fulfillment_status,

        -- Timestamps (all normalized to UTC)
        ordered_at,
        shipped_at,
        delivered_at,
        cancelled_at,

        -- Derived flags
        case
            when cancelled_at is not null then 1
            else 0
        end as is_cancelled,

        case
            when delivered_at is not null then 1
            else 0
        end as is_delivered,

        -- Calculate fulfillment time in days
        case
            when delivered_at is not null and ordered_at is not null
            then DATEDIFF('day', ordered_at, delivered_at)
            else null
        end as days_to_fulfill

    from all_orders

)

select * from final
SQL

echo "Fixed model created!"
echo ""
echo "=========================================="
echo "Running dbt pipeline"
echo "=========================================="

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps

# Run dbt to build just the model we fixed (not downstream dependencies)
dbt run --select int_sales__orders_enriched

echo ""
echo "=========================================="
echo "Solution completed successfully!"
echo "=========================================="
