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
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Overwrite generate_schema_name macro for Snowflake to ensure models go to target schema
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$DBT_PROJECT_DIR/macros/utils"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'SCHEMAEOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
SCHEMAEOF
fi

cd "$DBT_PROJECT_DIR"

# Create the attribution report model
mkdir -p models/marts

cat > models/marts/attribution_report.sql << 'EOF'
{{ config(materialized='table') }}

with sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
),

sales as (
    select * from {{ ref('stg_analytics__fact_sales') }}
),

-- Step 1: Hierarchical Channel Classification (Priority Order)
sessions_with_channel as (
    select
        session_id,
        customer_id,
        session_start,
        referrer,
        utm_source,
        utm_medium,
        device_type,
        duration_seconds,
        page_views,
        is_converted,
        order_id,
        case
            -- Priority 1: Paid Search
            when lower(utm_medium) in ('cpc', 'ppc') then 'Paid Search'
            -- Priority 2: Paid Social
            when lower(utm_medium) = 'paid_social'
                 or (lower(referrer) like '%facebook%' and utm_source is not null and utm_source != '')
                 then 'Paid Social'
            -- Priority 3: Organic Search
            when lower(referrer) like '%google%'
                 or lower(referrer) like '%bing%'
                 or lower(referrer) like '%yahoo%' then 'Organic Search'
            -- Priority 4: Organic Social
            when lower(referrer) like '%facebook%'
                 or lower(referrer) like '%twitter%'
                 or lower(referrer) like '%linkedin%'
                 or lower(referrer) like '%instagram%' then 'Organic Social'
            -- Priority 5: Email
            when lower(utm_medium) = 'email'
                 or lower(referrer) like '%mail%' then 'Email'
            -- Priority 6: Direct
            when referrer is null or referrer = '' then 'Direct'
            -- Priority 7: Referral
            else 'Referral'
        end as channel
    from sessions
),

-- Step 2: Session Quality Filtering
quality_sessions as (
    select *
    from sessions_with_channel
    where duration_seconds >= 5
      and page_views >= 2
      and lower(device_type) != 'bot'
),

-- Get conversion events with revenue
conversions as (
    select
        order_id,
        sum(total_amount) as revenue
    from sales
    where order_id is not null
    group by order_id
),

-- Get conversion timestamp from converting sessions
session_conversions as (
    select
        s.customer_id,
        c.order_id as conversion_id,
        c.revenue,
        s.session_start as conversion_at
    from sessions_with_channel s
    inner join conversions c on s.order_id = c.order_id
    where
        {% if target.type == 'snowflake' %}
        UPPER(CAST(s.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
        {% else %}
        s.is_converted = true
        {% endif %}
),

-- Step 3: Attribution Window (14-day lookback)
attributed_sessions as (
    select
        c.conversion_id,
        c.revenue,
        c.conversion_at,
        s.session_id,
        s.channel,
        s.session_start,
        {% if target.type == 'duckdb' %}
        date_diff('second', s.session_start, c.conversion_at) / 86400.0 as days_diff
        {% else %}
        DATEDIFF(second, s.session_start, c.conversion_at) / 86400.0 as days_diff
        {% endif %}
    from session_conversions c
    join quality_sessions s
        on c.customer_id = s.customer_id
        and s.session_start < c.conversion_at
        and s.session_start >= c.conversion_at - interval '14 days'
),

-- Step 4a: Position-Based Weight - Rank sessions per conversion
ranked_sessions as (
    select
        *,
        row_number() over (partition by conversion_id order by session_start) as position,
        count(*) over (partition by conversion_id) as total_sessions
    from attributed_sessions
),

-- Step 4b & 4c: Time-Decay and Combined Weight
weighted_sessions as (
    select
        *,
        -- Position multiplier: First=1.5, Last=1.3, Middle=1.0
        case
            when total_sessions = 1 then 1.0
            when position = 1 then 1.5
            when position = total_sessions then 1.3
            else 1.0
        end as position_multiplier,
        -- Time decay: e^(-t/7)
        exp(-days_diff / 7.0) as time_weight
    from ranked_sessions
),

combined_weights as (
    select
        *,
        position_multiplier * time_weight as raw_weight
    from weighted_sessions
),

-- Step 5: Cross-Channel Bonus - Count distinct channels per conversion
channel_diversity as (
    select
        conversion_id,
        count(distinct channel) as distinct_channels
    from combined_weights
    group by conversion_id
),

-- Apply cross-channel bonus to revenue
sessions_with_bonus as (
    select
        cw.*,
        case when cd.distinct_channels >= 3 then cw.revenue * 1.1 else cw.revenue end as adjusted_revenue
    from combined_weights cw
    join channel_diversity cd on cw.conversion_id = cd.conversion_id
),

-- Step 4d: Normalization
conversion_total_weights as (
    select
        conversion_id,
        sum(raw_weight) as total_weight
    from sessions_with_bonus
    group by conversion_id
),

final_attribution as (
    select
        swb.conversion_id,
        swb.channel,
        swb.adjusted_revenue,
        swb.raw_weight,
        ctw.total_weight,
        (swb.raw_weight / ctw.total_weight) as credit,
        (swb.raw_weight / ctw.total_weight) * swb.adjusted_revenue as attributed_revenue
    from sessions_with_bonus swb
    join conversion_total_weights ctw on swb.conversion_id = ctw.conversion_id
)

-- Step 6: Aggregation
select
    channel,
    round(sum(credit), 2) as total_conversions,
    round(sum(attributed_revenue), 2) as total_revenue
from final_attribution
group by channel
order by channel
EOF

# Run dbt
dbt deps
dbt run --select attribution_report stg_digital__web_sessions stg_analytics__fact_sales

# For Snowflake, create lowercase metadata views for info_schema compatibility
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set db = target.database %}
  {% set tables = ['attribution_report'] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "' ~ db ~ '"."main"."' ~ t ~ '" AS SELECT * FROM "' ~ db ~ '".MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi
