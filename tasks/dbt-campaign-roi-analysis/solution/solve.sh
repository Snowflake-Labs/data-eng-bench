#!/bin/bash
# Solution for dbt-campaign-roi-analysis task
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

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# For Snowflake: override generate_schema_name to put all task models in target schema
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$DBT_PROJECT_DIR/macros/utils"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is not none and custom_schema_name | trim != '' -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
GENMACRO
fi

cd "$DBT_PROJECT_DIR"

# Create required directories
mkdir -p models/staging/marketing
mkdir -p models/intermediate/marketing
mkdir -p models/marts/marketing
mkdir -p macros

# Create macro
cat > macros/calculate_roas.sql << 'EOF'
{% macro calculate_roas(revenue, spend, min_spend_threshold=1) %}
    CASE
        WHEN {{ spend }} < {{ min_spend_threshold }} THEN 0
        ELSE {{ revenue }} / NULLIF({{ spend }}, 0)
    END
{% endmacro %}
EOF

# Create staging model
cat > models/staging/marketing/stg_marketing__campaigns.sql << 'EOF'
WITH campaign_base AS (
    SELECT
        CAMPAIGN_ID as campaign_id,
        CAMPAIGN_NAME as campaign_name,
        UPPER(CHANNEL) as channel,
        START_DATE as start_date,
        END_DATE as end_date,
        BUDGET as total_budget,
        STATUS
    {% if target.type == 'snowflake' %}
    FROM RAW_GA.CAMPAIGNS
    {% else %}
    FROM main.CAMPAIGNS
    {% endif %}
),

performance AS (
    SELECT
        CAMPAIGN_ID as campaign_id,
        SUM(SPEND) as total_spend,
        SUM(IMPRESSIONS) as total_impressions,
        SUM(CLICKS) as total_clicks
    {% if target.type == 'snowflake' %}
    FROM MARKETING.CAMPAIGN_PERFORMANCE
    {% else %}
    FROM main.CAMPAIGN_PERFORMANCE
    {% endif %}
    GROUP BY CAMPAIGN_ID
)

SELECT
    c.campaign_id,
    c.campaign_name,
    c.channel,
    c.start_date,
    c.end_date,
    c.total_budget,
    COALESCE(p.total_spend, 0) as total_spend,
    COALESCE(p.total_impressions, 0) as total_impressions,
    COALESCE(p.total_clicks, 0) as total_clicks,
    CASE WHEN c.STATUS = 'ACTIVE' THEN 1 ELSE 0 END as is_active
FROM campaign_base c
LEFT JOIN performance p ON c.campaign_id = p.campaign_id
EOF

# Create intermediate model
cat > models/intermediate/marketing/int_marketing__attributed_conversions.sql << 'EOF'
WITH valid_campaigns AS (
    SELECT DISTINCT CAMPAIGN_ID as campaign_id
    {% if target.type == 'snowflake' %}
    FROM RAW_GA.CAMPAIGNS
    {% else %}
    FROM main.CAMPAIGNS
    {% endif %}
),

first_session_campaigns AS (
    SELECT
        s.CUSTOMER_ID as customer_id,
        s.UTM_CAMPAIGN as first_campaign_id,
        ROW_NUMBER() OVER (PARTITION BY s.CUSTOMER_ID ORDER BY s.SESSION_START) as rn
    {% if target.type == 'snowflake' %}
    FROM DIGITAL.WEB_SESSIONS s
    {% else %}
    FROM main.WEB_SESSIONS s
    {% endif %}
    INNER JOIN valid_campaigns c ON s.UTM_CAMPAIGN = c.campaign_id
    WHERE s.UTM_CAMPAIGN IS NOT NULL
),

first_campaigns AS (
    SELECT customer_id, first_campaign_id
    FROM first_session_campaigns
    WHERE rn = 1
),

converting_sessions AS (
    SELECT
        cv.CONVERSION_ID as conversion_id,
        cv.SESSION_ID as session_id,
        cv.VALUE as conversion_value,
        s.CUSTOMER_ID as customer_id,
        s.UTM_CAMPAIGN as last_campaign_id,
        s.ORDER_ID as order_id
    {% if target.type == 'snowflake' %}
    FROM RAW_GA.CONVERSIONS cv
    INNER JOIN DIGITAL.WEB_SESSIONS s ON cv.SESSION_ID = s.SESSION_ID
    {% else %}
    FROM main.CONVERSIONS cv
    INNER JOIN main.WEB_SESSIONS s ON cv.SESSION_ID = s.SESSION_ID
    {% endif %}
    INNER JOIN valid_campaigns c ON s.UTM_CAMPAIGN = c.campaign_id
    WHERE s.UTM_CAMPAIGN IS NOT NULL
    {% if target.type == 'snowflake' %}
      AND UPPER(CAST(s.IS_CONVERTED AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
    {% else %}
      AND s.IS_CONVERTED = true
    {% endif %}
),

orders AS (
    SELECT ORDER_ID as order_id, grand_total
    FROM {{ ref('int_sales__orders_enriched') }}
    {% if target.type == 'snowflake' %}
    WHERE UPPER(CAST(is_delivered AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
    {% else %}
    WHERE is_delivered = true
    {% endif %}
),

conversions_with_campaigns AS (
    SELECT
        cs.conversion_id,
        cs.session_id,
        cs.customer_id,
        cs.conversion_value,
        cs.last_campaign_id,
        fc.first_campaign_id,
        o.grand_total as order_value
    FROM converting_sessions cs
    LEFT JOIN first_campaigns fc ON cs.customer_id = fc.customer_id
    LEFT JOIN orders o ON cs.order_id = o.order_id
),

multi_touch AS (
    SELECT
        conversion_id, last_campaign_id as campaign_id, customer_id, session_id,
        conversion_value, order_value, 'multi_touch' as attribution_type,
        1.0 as attribution_weight,
        COALESCE(order_value, 0) * 1.0 as attributed_revenue
    FROM conversions_with_campaigns
    WHERE last_campaign_id = first_campaign_id
),

split_touch AS (
    SELECT conversion_id, customer_id, session_id, conversion_value, order_value,
           first_campaign_id, last_campaign_id
    FROM conversions_with_campaigns
    WHERE last_campaign_id != first_campaign_id OR first_campaign_id IS NULL
),

first_touch AS (
    SELECT
        conversion_id, first_campaign_id as campaign_id, customer_id, session_id,
        conversion_value, order_value, 'first_touch' as attribution_type,
        0.5 as attribution_weight,
        COALESCE(order_value, 0) * 0.5 as attributed_revenue
    FROM split_touch
    WHERE first_campaign_id IS NOT NULL
),

last_touch AS (
    SELECT
        conversion_id, last_campaign_id as campaign_id, customer_id, session_id,
        conversion_value, order_value, 'last_touch' as attribution_type,
        0.5 as attribution_weight,
        COALESCE(order_value, 0) * 0.5 as attributed_revenue
    FROM split_touch
)

SELECT * FROM multi_touch
UNION ALL
SELECT * FROM first_touch
UNION ALL
SELECT * FROM last_touch
EOF

# Create mart model
cat > models/marts/marketing/mart_marketing__campaign_roi.sql << 'EOF'
WITH campaign_base AS (
    SELECT
        campaign_id,
        campaign_name,
        channel,
        total_budget,
        total_spend,
        total_impressions,
        total_clicks
    FROM {{ ref('stg_marketing__campaigns') }}
),

attributed_metrics AS (
    SELECT
        campaign_id,
        COUNT(DISTINCT conversion_id) as total_attributed_conversions,
        SUM(attributed_revenue) as total_attributed_revenue
    FROM {{ ref('int_marketing__attributed_conversions') }}
    GROUP BY campaign_id
),

combined AS (
    SELECT
        c.campaign_id,
        c.campaign_name,
        c.channel,
        c.total_budget,
        c.total_spend,
        c.total_impressions,
        c.total_clicks,
        COALESCE(a.total_attributed_conversions, 0) as total_attributed_conversions,
        COALESCE(a.total_attributed_revenue, 0) as total_attributed_revenue
    FROM campaign_base c
    LEFT JOIN attributed_metrics a ON c.campaign_id = a.campaign_id
    WHERE c.total_spend > 0
),

metrics AS (
    SELECT
        *,
        {{ calculate_roas('total_attributed_revenue', 'total_spend', 1) }} as roas,
        CAST(total_clicks AS DOUBLE) / NULLIF(total_impressions, 0) * 100 as ctr,
        total_spend / NULLIF(total_clicks, 0) as cpc,
        total_spend / NULLIF(total_attributed_conversions, 0) as cpa,
        total_attributed_revenue / NULLIF(total_impressions, 0) as revenue_per_impression
    FROM combined
),

percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY roas ASC) as roas_percentile,
        PERCENT_RANK() OVER (ORDER BY cpa DESC) as cpa_percentile,
        PERCENT_RANK() OVER (ORDER BY ctr ASC) as ctr_percentile
    FROM metrics
),

median_revenue_per_imp AS (
    SELECT MEDIAN(revenue_per_impression) as median_value
    FROM metrics
    WHERE revenue_per_impression IS NOT NULL
),

effectiveness AS (
    SELECT
        p.*,
        m.median_value,
        LEAST(100.0, GREATEST(0.0,
            (LEAST(1.0, GREATEST(0.0, COALESCE(roas, 0) / 5.0)) * 0.40 +
             LEAST(1.0, GREATEST(0.0, COALESCE(ctr, 0) / 5.0)) * 0.25 +
             (1.0 - LEAST(1.0, GREATEST(0.0, COALESCE(cpa, 0) / 100.0))) * 0.20 +
             LEAST(1.0, GREATEST(0.0, COALESCE(revenue_per_impression, 0) / NULLIF(m.median_value, 0))) * 0.15) * 100
        )) as campaign_effectiveness_index
    FROM percentiles p
    CROSS JOIN median_revenue_per_imp m
),

peers AS (
    SELECT
        e.*,
        RANK() OVER (PARTITION BY channel ORDER BY roas DESC) as channel_roi_rank,
        COUNT(*) OVER (PARTITION BY channel) as channel_peer_count,
        AVG(roas) OVER (PARTITION BY channel) as channel_avg_roas
    FROM effectiveness e
)

SELECT
    campaign_id,
    campaign_name,
    channel,
    total_budget,
    total_spend,
    total_impressions,
    total_clicks,
    total_attributed_conversions,
    total_attributed_revenue,
    roas,
    ctr,
    cpc,
    cpa,
    revenue_per_impression,
    roas_percentile,
    cpa_percentile,
    ctr_percentile,
    CASE
        WHEN COALESCE(roas_percentile, 0) >= 0.75 AND COALESCE(roas, 0) >= 3.0 AND COALESCE(cpa, 999) < 50 THEN 'high_performer'
        WHEN COALESCE(roas_percentile, 0) >= 0.60 OR COALESCE(roas, 0) >= 2.0 THEN 'profitable'
        WHEN COALESCE(roas, 0) >= 1.0 OR COALESCE(roas_percentile, 0) >= 0.40 THEN 'break_even'
        ELSE 'underperforming'
    END as roi_tier,
    campaign_effectiveness_index,
    channel_roi_rank,
    channel_peer_count,
    CASE WHEN roas > channel_avg_roas THEN 1 ELSE 0 END as above_channel_avg_roas
FROM peers
EOF

# Install dependencies and run models
dbt deps
dbt run -s stg_marketing__campaigns int_marketing__attributed_conversions mart_marketing__campaign_roi
