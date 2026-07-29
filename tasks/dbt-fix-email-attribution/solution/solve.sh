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

echo "=========================================="
echo "Email Attribution Report - Solution Setup"
echo "=========================================="

# Step 1: Prepare reference models
echo ""
echo "Step 1: Preparing reference models..."

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
fi
echo "Using dbt project: $DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

if [ "$DB_TYPE" = "snowflake" ]; then
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
    echo "Configured Snowflake profile for reference models"
else
    if [ -f profiles.yml ]; then
        echo "Using existing profiles.yml"
    else
        DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
        cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
PROFILES
    fi
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# For Snowflake: override generate_schema_name to keep all models in default schema
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p macros/utils
    cat > macros/utils/generate_schema_name.sql << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {{ default_schema }}
{%- endmacro %}
GENMACRO
fi

dbt deps || echo "dbt deps completed with warnings"
dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined || echo "Reference models may already exist"

# Step 2: Set up agent project structure
echo ""
echo "Step 2: Setting up agent project..."
cd /app
mkdir -p dbt_project/models/marts/marketing

# Configure dbt profile
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > dbt_project/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile for dbt_project"
else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > dbt_project/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: analytics
PROFILES
fi

# Create dbt_project.yml
cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'
model-paths: ["models"]
EOF

# Step 3: Create the email attribution model
echo ""
echo "Step 3: Creating rpt_email_attribution_fixed model..."

cat > dbt_project/models/marts/marketing/rpt_email_attribution_fixed.sql << 'EOF'
{{
    config(
        materialized='table',
        tags=['marketing', 'email', 'attribution', 'ga4']
    )
}}

-- Check for available relations
{% set sessions_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_ga__sessions') %}
{% set events_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_ga__events') %}
{% set joined_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sessions_events_joined') %}

-- Check if joined table has revenue column
{% set has_joined_revenue = false %}
{% if joined_rel %}
  {% for col in adapter.get_columns_in_relation(joined_rel) %}
    {% if col.name | lower == 't2_event_value' %}
      {% set has_joined_revenue = true %}
    {% endif %}
  {% endfor %}
{% endif %}

-- Normalize sessions with proper UTM handling and date filtering
-- First get all session rows, then deduplicate to one row per session_id
WITH raw_sessions AS (
    SELECT
        TRIM(CAST(s.session_id AS VARCHAR)) AS session_id,
        CAST(s.session_start AS DATE) AS attribution_date,
        CASE
            WHEN s.utm_source IS NULL OR TRIM(COALESCE(s.utm_source, '')) = '' THEN 'direct'
            ELSE TRIM(s.utm_source)
        END AS channel,
        CASE
            WHEN s.utm_medium IS NULL OR TRIM(COALESCE(s.utm_medium, '')) = '' THEN 'none'
            ELSE TRIM(s.utm_medium)
        END AS medium,
        CASE
            WHEN s.utm_campaign IS NULL OR TRIM(COALESCE(s.utm_campaign, '')) = '' THEN 'none'
            ELSE TRIM(s.utm_campaign)
        END AS campaign,
        CASE
            WHEN s.is_converted IS NULL THEN false
            WHEN TRIM(CAST(s.is_converted AS VARCHAR)) = '' THEN false
            WHEN LOWER(TRIM(CAST(s.is_converted AS VARCHAR))) IN ('1', 'true', 't', 'yes', 'y', '1.0', '1.00') THEN true
            WHEN LOWER(TRIM(CAST(s.is_converted AS VARCHAR))) IN ('0', 'false', 'f', 'no', 'n', '0.0', '0.00', 'null') THEN false
            WHEN TRY_CAST(TRIM(CAST(s.is_converted AS VARCHAR)) AS DOUBLE) IS NOT NULL
                THEN (TRY_CAST(TRIM(CAST(s.is_converted AS VARCHAR)) AS DOUBLE) != 0)
            ELSE false
        END AS is_converted,
        s.session_start,
        ROW_NUMBER() OVER (PARTITION BY TRIM(CAST(s.session_id AS VARCHAR)) ORDER BY s.session_start) as rn
    FROM {{ sessions_rel }} s
    WHERE s.session_id IS NOT NULL
      AND TRIM(CAST(s.session_id AS VARCHAR)) != ''
      AND s.session_start IS NOT NULL
      {% if target.type == 'snowflake' %}
      AND CAST(s.session_start AS DATE) >= '2025-10-04'
      {% else %}
      AND CAST(s.session_start AS DATE) >= DATE '2025-10-04'
      {% endif %}
      AND CAST(s.session_start AS DATE) <= DATE '2026-01-02'
),

normalized_sessions AS (
    SELECT session_id, attribution_date, channel, medium, campaign, is_converted, session_start
    FROM raw_sessions
    WHERE rn = 1
),

-- Revenue from joined table (preferred source)
revenue_from_joined AS (
    {% if has_joined_revenue %}
        SELECT
            TRIM(CAST(j.session_id AS VARCHAR)) AS session_id,
            ROUND(SUM(GREATEST(COALESCE(TRY_CAST(j.t2_event_value AS DECIMAL(12,2)), 0), 0)), 2) AS conversion_value
        FROM {{ joined_rel }} j
        JOIN normalized_sessions ns
          ON TRIM(CAST(j.session_id AS VARCHAR)) = ns.session_id
        WHERE ns.is_converted = true
          AND j.t2_event_name = 'purchase'
          AND j.t2_event_value IS NOT NULL
        GROUP BY TRIM(CAST(j.session_id AS VARCHAR))
    {% else %}
        SELECT CAST(NULL AS VARCHAR) AS session_id, CAST(0 AS DECIMAL(12,2)) AS conversion_value WHERE 1=0
    {% endif %}
),

-- Revenue from events table (fallback)
revenue_from_events AS (
    {% if events_rel %}
        SELECT
            TRIM(CAST(e.session_id AS VARCHAR)) AS session_id,
            ROUND(SUM(GREATEST(COALESCE(TRY_CAST(e.event_value AS DECIMAL(12,2)), 0), 0)), 2) AS conversion_value
        FROM {{ events_rel }} e
        JOIN normalized_sessions ns
          ON TRIM(CAST(e.session_id AS VARCHAR)) = ns.session_id
        WHERE ns.is_converted = true
          AND e.event_name = 'purchase'
          AND e.event_value IS NOT NULL
        GROUP BY TRIM(CAST(e.session_id AS VARCHAR))
    {% else %}
        SELECT CAST(NULL AS VARCHAR) AS session_id, CAST(0 AS DECIMAL(12,2)) AS conversion_value WHERE 1=0
    {% endif %}
),

-- Combine revenue sources (prefer joined, fallback to events) - dedup to one row per session
session_revenue AS (
    SELECT
        session_id,
        MAX(conversion_value) as conversion_value
    FROM (
        SELECT
            COALESCE(rj.session_id, re.session_id) AS session_id,
            COALESCE(rj.conversion_value, re.conversion_value, 0) AS conversion_value
        FROM revenue_from_joined rj
        FULL OUTER JOIN revenue_from_events re
            ON rj.session_id = re.session_id
    ) combined
    GROUP BY session_id
)

-- Final aggregation
SELECT
    ns.attribution_date,
    ns.channel,
    ns.medium,
    ns.campaign,
    CAST(COUNT(DISTINCT ns.session_id) AS BIGINT) AS sessions,
    CAST(COUNT(DISTINCT CASE WHEN ns.is_converted THEN ns.session_id END) AS BIGINT) AS conversions,
    CAST(ROUND(COALESCE(SUM(sr.conversion_value), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
    CAST(
        CASE
            WHEN COUNT(DISTINCT ns.session_id) > 0 THEN
                ROUND(
                    CAST(SUM(CASE WHEN ns.is_converted THEN 1 ELSE 0 END) AS DECIMAL(18,8)) /
                    CAST(COUNT(DISTINCT ns.session_id) AS DECIMAL(18,8)),
                    4
                )
            ELSE CAST(0.0 AS DECIMAL(10,4))
        END
        AS DECIMAL(10,4)
    ) AS conversion_rate
FROM normalized_sessions ns
LEFT JOIN session_revenue sr ON ns.session_id = sr.session_id
GROUP BY ns.attribution_date, ns.channel, ns.medium, ns.campaign
HAVING COUNT(DISTINCT ns.session_id) > 0
ORDER BY ns.attribution_date DESC, ns.channel, ns.medium, ns.campaign
EOF

# Step 4: Run the model
echo ""
echo "Step 4: Running dbt model..."
cd /app/dbt_project
export DBT_PROFILES_DIR="/app/dbt_project"
dbt run --select rpt_email_attribution_fixed --full-refresh

echo ""
echo "=========================================="
echo "✓ Solution complete!"
echo "=========================================="
