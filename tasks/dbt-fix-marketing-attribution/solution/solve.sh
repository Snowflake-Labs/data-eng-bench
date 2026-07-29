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
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project

    # Overwrite generate_schema_name macro to output to 'main' schema
    mkdir -p "$DBT_PROJECT_DIR/macros/utils"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
MACRO

else
    DBT_PROJECT_DIR="/app/dbt_project"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # First, run the reference dbt project to materialize source models
    echo "Running reference dbt project to materialize source models..."
    cd /app/dbt_models_duckdb
    mkdir -p ~/.dbt

    # Use the profiles.yml from dbt_models_duckdb if it exists, otherwise create a minimal one
    if [ -f profiles.yml ]; then
        cp profiles.yml ~/.dbt/profiles.yml
        echo "Using existing profiles.yml from dbt_models_duckdb"
    else
        cat > ~/.dbt/profiles.yml << 'EOF'
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
EOF
    fi

    # Install dependencies and run reference models
    dbt deps || echo "Dependencies may already be installed, continuing..."
    echo "Materializing reference models..."
    dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined || echo "Some models may already exist, continuing..."

    # Now create the agent's dbt project
    cd /app
    mkdir -p "$DBT_PROJECT_DIR/models/marts/marketing"

    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: analytics
      threads: 4
PROFILES

    cat > "$DBT_PROJECT_DIR/dbt_project.yml" << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'
model-paths: ["models"]
EOF

fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create model directory structure
mkdir -p "$DBT_PROJECT_DIR/models/marts/marketing"

# Create the fixed attribution model
# Uses Jinja adapter introspection for cross-DB column detection
# Uses ANSI SQL compatible syntax for both DuckDB and Snowflake
cat > "$DBT_PROJECT_DIR/models/marts/marketing/rpt_attribution_fixed.sql" << 'SQLEOF'
{{
    config(
        materialized='table',
        tags=['marketing', 'attribution', 'ga4']
    )
}}

{% set sessions_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_ga__sessions') %}
{% set events_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_ga__events') %}
{% set joined_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sessions_events_joined') %}
{% set has_joined_revenue = false %}
{% if joined_rel %}
  {% for col in adapter.get_columns_in_relation(joined_rel) %}
    {% if col.name | lower == 't2_event_value' %}
      {% set has_joined_revenue = true %}
    {% endif %}
  {% endfor %}
{% endif %}

WITH sessions_base AS (
    SELECT DISTINCT
        s.session_id,
        CAST(s.session_start AS DATE) AS attribution_date,
        COALESCE(s.utm_source, 'direct') AS channel,
        COALESCE(s.utm_medium, 'none') AS medium,
        COALESCE(s.utm_campaign, 'none') AS campaign,
        s.is_converted,
        s.session_start
    FROM {{ sessions_rel }} s
    WHERE s.session_id IS NOT NULL
      AND s.session_start IS NOT NULL
      AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}) - interval '90 days'
),

conversion_revenue AS (
    {% if has_joined_revenue %}
        SELECT
            j.session_id,
            ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
        FROM {{ joined_rel }} j
        JOIN {{ sessions_rel }} s
          ON j.session_id = s.session_id
        WHERE UPPER(CAST(s.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
          AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}) - interval '90 days'
          AND j.t2_event_name = 'purchase'
        GROUP BY j.session_id
    {% elif events_rel %}
        SELECT
            e.session_id,
            ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
        FROM {{ events_rel }} e
        JOIN {{ sessions_rel }} s
          ON e.session_id = s.session_id
        WHERE UPPER(CAST(s.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')
          AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}) - interval '90 days'
          AND e.event_name = 'purchase'
        GROUP BY e.session_id
    {% else %}
        SELECT CAST(NULL AS VARCHAR) AS session_id, CAST(0 AS DECIMAL(12,2)) AS conversion_value WHERE 1=0
    {% endif %}
)

SELECT
    sb.attribution_date,
    sb.channel,
    sb.medium,
    sb.campaign,
    CAST(COUNT(DISTINCT sb.session_id) AS BIGINT) AS sessions,
    CAST(SUM(CASE WHEN UPPER(CAST(sb.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') THEN 1 ELSE 0 END) AS BIGINT) AS conversions,
    CAST(ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
    CASE
        WHEN COUNT(DISTINCT sb.session_id) > 0
        THEN CAST(ROUND(
            CAST(SUM(CASE WHEN UPPER(CAST(sb.is_converted AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') THEN 1 ELSE 0 END) AS DECIMAL(18,8)) /
            CAST(COUNT(DISTINCT sb.session_id) AS DECIMAL(18,8)),
            4
        ) AS DECIMAL(10,4))
        ELSE CAST(0.0 AS DECIMAL(10,4))
    END AS conversion_rate
FROM sessions_base sb
LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
GROUP BY
    sb.attribution_date,
    sb.channel,
    sb.medium,
    sb.campaign
ORDER BY
    sb.attribution_date DESC,
    sb.channel,
    sb.medium,
    sb.campaign
SQLEOF

# For Snowflake, run reference models first (stg_ga__sessions, stg_ga__events, int_sessions_events_joined)
if [ "$DB_TYPE" = "snowflake" ]; then
    cd "$DBT_PROJECT_DIR"
    echo "Installing dbt dependencies..."
    dbt deps
    echo "Running reference models for Snowflake..."
    dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined
fi

cd "$DBT_PROJECT_DIR"
dbt deps
dbt run --select rpt_attribution_fixed

echo "Solution complete!"
