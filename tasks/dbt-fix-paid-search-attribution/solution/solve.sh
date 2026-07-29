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

# ====== Step 1: Set up project and build reference models ======
echo "Setting up project..."

DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"

mkdir -p "$DBT_PROJECT_DIR/models/marts/marketing"
mkdir -p "$DBT_PROJECT_DIR/macros/utils"

# Create profiles.yml
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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
else
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: main
      threads: 4
PROFILES
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Build reference staging models
echo "Building reference models..."
cd "$DBT_PROJECT_DIR"
dbt deps || echo "deps already installed"
dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined || echo "reference run best effort"

cat > "$DBT_PROJECT_DIR/dbt_project.yml" << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'
model-paths: ["models"]
macro-paths: ["macros"]
EOF

# ====== Step 3: generate_schema_name macro ======
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# ====== Step 4: Pre-create analytics schema for Snowflake ======
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating analytics schema with admin role..."
    python3 << 'PRECREATE_PY'
import os
import base64
import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

def get_private_key():
    private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
    private_key_pem = base64.b64decode(private_key_b64)
    passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    passphrase_bytes = passphrase.encode() if passphrase else None
    p_key = serialization.load_pem_private_key(
        private_key_pem,
        password=passphrase_bytes,
        backend=default_backend()
    )
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )

try:
    conn = snowflake.connector.connect(
        account=os.environ['SNOWFLAKE_ACCOUNT'],
        host=os.environ.get('SNOWFLAKE_HOST') or None,
        user=os.environ['SNOWFLAKE_USER'],
        private_key=get_private_key(),
        database=os.environ['SNOWFLAKE_DATABASE'],
        warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
        role=os.environ.get('SNOWFLAKE_ADMIN_ROLE', '')
    )
    cur = conn.cursor()
    db = os.environ['SNOWFLAKE_DATABASE']
    agent_role = os.environ.get('SNOWFLAKE_AGENT_ROLE', os.environ.get('SNOWFLAKE_ROLE', ''))

    # Create analytics schema
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{db}"."analytics"')
    if agent_role:
        cur.execute(f'GRANT USAGE ON SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
    print(f"Pre-created analytics schema in {db}")
    cur.close()
    conn.close()
except Exception as e:
    print(f"Warning: Could not pre-create analytics schema: {e}")
PRECREATE_PY
fi

# ====== Step 5: Create the model SQL ======
echo "Creating rpt_paid_search_attribution_fixed model..."

cat > "$DBT_PROJECT_DIR/models/marts/marketing/rpt_paid_search_attribution_fixed.sql" << 'EOF'
{{
    config(
        materialized='table',
        schema='analytics',
        tags=['marketing', 'paid_search', 'ga4']
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
      {% if target.type == 'snowflake' %}
      AND CAST(s.session_start AS DATE) >= DATEADD(day, -90, (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}))
      {% else %}
      AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}) - INTERVAL '90 days'
      {% endif %}
),

conversion_revenue AS (
    {% if has_joined_revenue %}
        SELECT
            j.session_id,
            ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
        FROM {{ joined_rel }} j
        JOIN {{ sessions_rel }} s
          ON j.session_id = s.session_id
        WHERE s.is_converted = true
          {% if target.type == 'snowflake' %}
          AND CAST(s.session_start AS DATE) >= DATEADD(day, -90, (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}))
          {% else %}
          AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}) - INTERVAL '90 days'
          {% endif %}
          AND j.t2_event_name = 'purchase'
        GROUP BY j.session_id
    {% elif events_rel %}
        SELECT
            e.session_id,
            ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
        FROM {{ events_rel }} e
        JOIN {{ sessions_rel }} s
          ON e.session_id = s.session_id
        WHERE s.is_converted = true
          {% if target.type == 'snowflake' %}
          AND CAST(s.session_start AS DATE) >= DATEADD(day, -90, (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}))
          {% else %}
          AND CAST(s.session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM {{ sessions_rel }}) - INTERVAL '90 days'
          {% endif %}
          AND e.event_name = 'purchase'
        GROUP BY e.session_id
    {% else %}
        SELECT NULL::VARCHAR AS session_id, 0::DECIMAL(12,2) AS conversion_value WHERE FALSE
    {% endif %}
)

SELECT
    sb.attribution_date,
    sb.channel,
    sb.medium,
    sb.campaign,
    CAST(COUNT(DISTINCT sb.session_id) AS BIGINT) AS sessions,
    CAST(SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS BIGINT) AS conversions,
    CAST(ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue,
    CASE
        WHEN COUNT(DISTINCT sb.session_id) > 0
        THEN CAST(ROUND(
            CAST(SUM(CASE WHEN sb.is_converted = true THEN 1 ELSE 0 END) AS DECIMAL(18,8)) /
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
EOF

# ====== Step 6: Run dbt ======
echo "Running dbt to build model..."
cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps || echo "No dependencies needed"
dbt run --select rpt_paid_search_attribution_fixed

echo "Solution complete!"
