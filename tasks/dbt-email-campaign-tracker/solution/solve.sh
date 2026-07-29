#!/bin/bash
set -euo pipefail

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

cd "$DBT_PROJECT_DIR"

# Create directories
mkdir -p models/staging/marketing
mkdir -p models/intermediate/marketing
mkdir -p models/marts/marketing

# No need to create sources.yml - both base projects already define
# the 'sfdc' source (schema RAW_SFDC) with EMAIL_CAMPAIGNS and CAMPAIGNS tables.

# Create the engagement score macro
cat > macros/calculate_engagement_score.sql << 'EOF'
{% macro calculate_engagement_score(open_rate, click_rate, cto_rate) %}
    (COALESCE({{ open_rate }}, 0) * 0.40 + COALESCE({{ click_rate }}, 0) * 0.35 + COALESCE({{ cto_rate }}, 0) * 0.25) * 100
{% endmacro %}
EOF

# Staging model - uses Jinja conditional for CAST type (DOUBLE vs FLOAT)
cat > models/staging/marketing/stg_marketing__email_metrics.sql << 'EOF'
SELECT
    ec.EMAIL_CAMPAIGN_ID as email_campaign_id,
    c.CAMPAIGN_NAME as campaign_name,
    'General' as segment_name,
    ec.SENT_DATE as sent_date,
    ec.TOTAL_SENT as total_sent,
    ec.TOTAL_DELIVERED as total_delivered,
    ec.TOTAL_OPENED as total_opened,
    ec.TOTAL_CLICKED as total_clicked,
    {% if target.type == 'snowflake' %}
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_DELIVERED AS FLOAT) / NULLIF(ec.TOTAL_SENT, 0), 0)) as delivery_rate,
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_OPENED AS FLOAT) / NULLIF(ec.TOTAL_DELIVERED, 0), 0)) as open_rate,
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_CLICKED AS FLOAT) / NULLIF(ec.TOTAL_DELIVERED, 0), 0)) as click_rate,
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_CLICKED AS FLOAT) / NULLIF(ec.TOTAL_OPENED, 0), 0)) as click_to_open_rate
    {% else %}
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_DELIVERED AS DOUBLE) / NULLIF(ec.TOTAL_SENT, 0), 0)) as delivery_rate,
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_OPENED AS DOUBLE) / NULLIF(ec.TOTAL_DELIVERED, 0), 0)) as open_rate,
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_CLICKED AS DOUBLE) / NULLIF(ec.TOTAL_DELIVERED, 0), 0)) as click_rate,
    LEAST(1.0, COALESCE(CAST(ec.TOTAL_CLICKED AS DOUBLE) / NULLIF(ec.TOTAL_OPENED, 0), 0)) as click_to_open_rate
    {% endif %}
FROM {{ source('sfdc', 'EMAIL_CAMPAIGNS') }} ec
LEFT JOIN {{ source('sfdc', 'CAMPAIGNS') }} c ON ec.CAMPAIGN_ID = c.CAMPAIGN_ID
WHERE ec.TOTAL_SENT > 0
EOF

# Intermediate model - uses Jinja conditional for window frame syntax
# DuckDB uses RANGE BETWEEN INTERVAL; Snowflake uses ROWS BETWEEN (RANGE not supported with timestamp ORDER BY)
cat > models/intermediate/marketing/int_marketing__email_performance.sql << 'EOF'
WITH base AS (
    SELECT * FROM {{ ref('stg_marketing__email_metrics') }}
),
enriched AS (
    SELECT
        *,
        {{ calculate_engagement_score('open_rate', 'click_rate', 'click_to_open_rate') }} as engagement_score,
        COUNT(*) OVER (
            PARTITION BY segment_name
            ORDER BY sent_date
            {% if target.type == 'snowflake' %}
            ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
            {% else %}
            RANGE BETWEEN INTERVAL '30' DAY PRECEDING AND CURRENT ROW
            {% endif %}
        ) as emails_sent_last_30d,
        AVG(open_rate) OVER (
            PARTITION BY segment_name
            ORDER BY sent_date, email_campaign_id
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) as avg_segment_open_rate
    FROM base
)
SELECT
    *,
    CASE
        WHEN open_rate < avg_segment_open_rate * 0.70 AND emails_sent_last_30d >= 4 THEN 1
        ELSE 0
    END as fatigue_indicator
FROM enriched
EOF

# Mart model - MEDIAN, PERCENT_RANK, LEAST/GREATEST all work on both backends
cat > models/marts/marketing/mart_marketing__email_scorecard.sql << 'EOF'
WITH perf AS (
    SELECT * FROM {{ ref('int_marketing__email_performance') }}
),
percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY engagement_score ASC, email_campaign_id) as engagement_percentile,
        PERCENT_RANK() OVER (ORDER BY open_rate ASC, email_campaign_id) as open_rate_percentile,
        PERCENT_RANK() OVER (ORDER BY delivery_rate ASC, email_campaign_id) as delivery_percentile
    FROM perf
),
median_click AS (
    SELECT MEDIAN(click_rate) as median_value FROM perf WHERE click_rate IS NOT NULL
),
effectiveness AS (
    SELECT
        p.*,
        m.median_value,
        LEAST(100, GREATEST(0,
            (engagement_score / 100.0 * 0.40 +
             COALESCE(delivery_rate, 0) * 0.25 +
             COALESCE(open_rate, 0) * 0.20 +
             LEAST(1, COALESCE(click_rate, 0) / NULLIF(m.median_value, 0)) * 0.15) * 100
        )) as campaign_effectiveness_index,
        CASE
            WHEN COALESCE(engagement_percentile, 0) >= 0.75 AND COALESCE(open_rate, 0) >= 0.25 AND COALESCE(click_rate, 0) >= 0.03 THEN 'excellent'
            WHEN COALESCE(engagement_percentile, 0) >= 0.50 OR COALESCE(open_rate, 0) >= 0.20 THEN 'good'
            WHEN COALESCE(engagement_percentile, 0) >= 0.30 OR COALESCE(open_rate, 0) >= 0.15 THEN 'average'
            ELSE 'poor'
        END as performance_tier
    FROM percentiles p
    CROSS JOIN median_click m
),
peers AS (
    SELECT
        e.*,
        RANK() OVER (PARTITION BY segment_name ORDER BY engagement_score DESC, email_campaign_id) as segment_performance_rank,
        COUNT(*) OVER (PARTITION BY segment_name) as segment_peer_count,
        AVG(engagement_score) OVER (PARTITION BY segment_name) as segment_avg_engagement
    FROM effectiveness e
)
SELECT
    email_campaign_id, campaign_name, segment_name, sent_date, total_sent, total_delivered,
    total_opened, total_clicked, delivery_rate, open_rate, click_rate, click_to_open_rate,
    engagement_score, emails_sent_last_30d, avg_segment_open_rate, fatigue_indicator,
    engagement_percentile, open_rate_percentile, delivery_percentile, performance_tier,
    campaign_effectiveness_index, segment_performance_rank, segment_peer_count,
    CASE WHEN engagement_score > segment_avg_engagement THEN 1 ELSE 0 END as above_segment_avg_engagement
FROM peers
EOF

dbt deps
dbt run -s stg_marketing__email_metrics int_marketing__email_performance mart_marketing__email_scorecard
