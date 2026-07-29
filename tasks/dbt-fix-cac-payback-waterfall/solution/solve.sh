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

# Note: The base image includes dbt + DuckDB + /app/dbt_transforms with reference models
# already materialized in the main schema. We only need to create the agent's dbt project.

echo "Setting up agent project..."
cd /app
mkdir -p ~/.dbt
mkdir -p dbt_project/models/marts/marketing
mkdir -p dbt_project/macros/utils

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile - uses private key authentication
    cat > dbt_project/profiles.yml <<PROFILES
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
    cat > dbt_project/profiles.yml <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'
model-paths: ["models"]
macro-paths: ["macros"]
EOF

# Create generate_schema_name macro to respect custom schema config
cat > dbt_project/macros/utils/generate_schema_name.sql << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}
    {%- endif -%}
{%- endmacro %}
MACRO

# Pre-create analytics schema on Snowflake using admin role
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Pre-creating analytics schema on Snowflake with admin role..."
    ADMIN_ROLE="${SNOWFLAKE_ADMIN_ROLE:-HARBOR_ADMIN}"
    python3 - <<PYEOF
import snowflake.connector
import base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization
import os

private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
private_key_pem = base64.b64decode(private_key_b64)
passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
passphrase_bytes = passphrase.encode() if passphrase else None
p_key = serialization.load_pem_private_key(
    private_key_pem,
    password=passphrase_bytes,
    backend=default_backend()
)
pkb = p_key.private_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
)

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    database=os.environ['SNOWFLAKE_DATABASE'],
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role='${ADMIN_ROLE}'
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE'].upper()
cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{db}"."analytics"')
agent_role = os.environ.get('SNOWFLAKE_ROLE', os.environ.get('SNOWFLAKE_AGENT_ROLE', ''))
if agent_role:
    agent_role = agent_role.upper()
    cur.execute(f'GRANT USAGE ON SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
    cur.execute(f'GRANT SELECT ON FUTURE TABLES IN SCHEMA "{db}"."analytics" TO ROLE "{agent_role}"')
print("Analytics schema created and permissions granted")
cur.close()
conn.close()
PYEOF
fi

cat > dbt_project/models/marts/marketing/rpt_cac_payback_waterfall_fixed.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='analytics',
        tags=['marketing', 'cac', 'payback']
    )
}}

{% if target.type == 'snowflake' %}

{# --- Snowflake SQL --- #}

{% set spend_rel = adapter.get_relation(database=target.database, schema='main', identifier='STG_FACT_MARKETING_SPEND') %}
{% if not spend_rel %}
  {% set spend_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_fact_marketing_spend') %}
{% endif %}
{% if not spend_rel %}
  {% set spend_rel = adapter.get_relation(database=target.database, schema='MAIN', identifier='STG_FACT_MARKETING_SPEND') %}
{% endif %}

WITH base AS (
  SELECT
    COALESCE(
      TRY_TO_DATE(TO_VARCHAR(date_key), 'YYYYMMDD'),
      TRY_TO_DATE(TO_VARCHAR(date_key), 'YYYY-MM-DD'),
      TRY_TO_DATE(TO_VARCHAR(date_key))
    ) AS spend_date,
    campaign_id,
    CAST(channel_key AS INTEGER) AS channel_key,
    ROUND(CAST(spend_amount AS DECIMAL(18,2)), 2) AS spend_amount,
    ROUND(CAST(revenue_attributed AS DECIMAL(18,2)), 2) AS revenue_attributed
  FROM {{ spend_rel }}
  WHERE campaign_id IS NOT NULL
),

cohorts AS (
  SELECT
    campaign_id,
    ANY_VALUE(channel_key) AS channel_key,
    MIN(spend_date) AS cohort_date
  FROM base
  GROUP BY 1
),

daily AS (
  SELECT
    b.campaign_id,
    c.channel_key,
    c.cohort_date,
    DATEDIFF('day', c.cohort_date, b.spend_date) AS days_since_cohort,
    ROUND(SUM(b.spend_amount), 2) AS daily_spend,
    ROUND(SUM(b.revenue_attributed), 2) AS daily_revenue_attributed
  FROM base b
  JOIN cohorts c USING (campaign_id)
  GROUP BY 1,2,3,4
),

final AS (
  SELECT
    campaign_id,
    channel_key,
    cohort_date,
    CAST(days_since_cohort AS INTEGER) AS days_since_cohort,
    CAST(daily_spend AS DECIMAL(12,2)) AS daily_spend,
    CAST(daily_revenue_attributed AS DECIMAL(12,2)) AS daily_revenue_attributed,
    CAST(
      ROUND(SUM(daily_spend) OVER (PARTITION BY campaign_id ORDER BY days_since_cohort ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)
      AS DECIMAL(12,2)
    ) AS cumulative_spend,
    CAST(
      ROUND(SUM(daily_revenue_attributed) OVER (PARTITION BY campaign_id ORDER BY days_since_cohort ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)
      AS DECIMAL(12,2)
    ) AS cumulative_revenue
  FROM daily
)

SELECT
  campaign_id,
  channel_key,
  cohort_date,
  days_since_cohort,
  daily_spend,
  daily_revenue_attributed,
  cumulative_spend,
  cumulative_revenue,
  CAST(
    CASE
      WHEN cumulative_spend > 0 THEN ROUND(CAST(cumulative_revenue AS DECIMAL(18,8)) / CAST(cumulative_spend AS DECIMAL(18,8)), 4)
      ELSE 0.0
    END
    AS DECIMAL(10,4)
  ) AS payback_ratio,
  CASE WHEN cumulative_revenue >= cumulative_spend THEN TRUE ELSE FALSE END AS is_paid_back
FROM final
ORDER BY campaign_id, days_since_cohort

{% else %}

{# --- DuckDB SQL --- #}

{% set spend_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_fact_marketing_spend') %}
{% if not spend_rel %}
  {% set spend_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_analytics__fact_marketing_spend') %}
{% endif %}

WITH base AS (
  SELECT
    CASE
      WHEN typeof(date_key) = 'DATE' THEN CAST(date_key AS DATE)
      ELSE CAST(strptime(CAST(date_key AS VARCHAR), '%Y%m%d') AS DATE)
    END AS spend_date,
    campaign_id,
    CAST(channel_key AS INTEGER) AS channel_key,
    ROUND(CAST(spend_amount AS DECIMAL(18,2)), 2) AS spend_amount,
    ROUND(CAST(revenue_attributed AS DECIMAL(18,2)), 2) AS revenue_attributed
  FROM {{ spend_rel }}
  WHERE campaign_id IS NOT NULL
),

cohorts AS (
  SELECT
    campaign_id,
    ANY_VALUE(channel_key) AS channel_key,
    MIN(spend_date) AS cohort_date
  FROM base
  GROUP BY 1
),

daily AS (
  SELECT
    b.campaign_id,
    c.channel_key,
    c.cohort_date,
    DATE_DIFF('day', c.cohort_date, b.spend_date) AS days_since_cohort,
    ROUND(SUM(b.spend_amount), 2) AS daily_spend,
    ROUND(SUM(b.revenue_attributed), 2) AS daily_revenue_attributed
  FROM base b
  JOIN cohorts c USING (campaign_id)
  GROUP BY 1,2,3,4
),

final AS (
  SELECT
    campaign_id,
    channel_key,
    cohort_date,
    CAST(days_since_cohort AS INTEGER) AS days_since_cohort,
    CAST(daily_spend AS DECIMAL(12,2)) AS daily_spend,
    CAST(daily_revenue_attributed AS DECIMAL(12,2)) AS daily_revenue_attributed,
    CAST(
      ROUND(SUM(daily_spend) OVER (PARTITION BY campaign_id ORDER BY days_since_cohort ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)
      AS DECIMAL(12,2)
    ) AS cumulative_spend,
    CAST(
      ROUND(SUM(daily_revenue_attributed) OVER (PARTITION BY campaign_id ORDER BY days_since_cohort ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)
      AS DECIMAL(12,2)
    ) AS cumulative_revenue
  FROM daily
)

SELECT
  campaign_id,
  channel_key,
  cohort_date,
  days_since_cohort,
  daily_spend,
  daily_revenue_attributed,
  cumulative_spend,
  cumulative_revenue,
  CAST(
    CASE
      WHEN cumulative_spend > 0 THEN ROUND(CAST(cumulative_revenue AS DECIMAL(18,8)) / CAST(cumulative_spend AS DECIMAL(18,8)), 4)
      ELSE 0.0
    END
    AS DECIMAL(10,4)
  ) AS payback_ratio,
  (cumulative_revenue >= cumulative_spend) AS is_paid_back
FROM final
ORDER BY campaign_id, days_since_cohort

{% endif %}
EOF

cd /app/dbt_project
export DBT_PROFILES_DIR=/app/dbt_project

dbt deps || true
dbt run --select rpt_cac_payback_waterfall_fixed

echo "Solution complete!"
