#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

echo "Preparing reference models..."

# Set dbt project directory for the reference models (existing project)
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
else
    DBT_PROJECT_DIR="/app/dbt_models_duckdb"
fi
echo "Using dbt project: $DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

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
dbt deps || echo "deps already installed"
dbt run --select int_sales__orders_enriched

echo "Setting up agent project..."
cd /app
mkdir -p dbt_project/models/marts/customer

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
    echo "Configured Snowflake profile for agent project"
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

cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'
model-paths: ["models"]
EOF

cat > dbt_project/models/marts/customer/rpt_customer_cltv_forecast.sql << 'EOF'
{{
    config(
        materialized='table',
        tags=['customer', 'cltv', 'forecast']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}

WITH orders AS (
  SELECT
    customer_id,
    order_id,
    CAST(ordered_at AS DATE) AS order_date,
    CAST(grand_total AS DECIMAL(18,2)) AS grand_total
  FROM {{ orders_rel }}
  WHERE customer_id IS NOT NULL
    AND ordered_at IS NOT NULL
    AND is_cancelled = false
),

as_of AS (
  SELECT MAX(order_date) AS as_of_date FROM orders
),

customer_metrics AS (
  SELECT
    o.customer_id,
    a.as_of_date,
    ROUND(SUM(o.grand_total), 2) AS current_lifetime_revenue,
    COUNT(DISTINCT o.order_id) AS current_order_count,
    MAX(o.order_date) AS last_order_date
  FROM orders o
  CROSS JOIN as_of a
  WHERE o.order_date <= a.as_of_date
  GROUP BY o.customer_id, a.as_of_date
),

monthly_revenue AS (
  SELECT
    o.customer_id,
    DATE_TRUNC('month', o.order_date) AS month_start,
    ROUND(SUM(o.grand_total), 2) AS monthly_revenue
  FROM orders o
  CROSS JOIN as_of a
  WHERE o.order_date >= DATE_TRUNC('month', a.as_of_date - INTERVAL '6 months')
    AND o.order_date < DATE_TRUNC('month', a.as_of_date)
  GROUP BY o.customer_id, DATE_TRUNC('month', o.order_date)
),

avg_monthly_revenue AS (
  SELECT
    customer_id,
    CASE
      WHEN COUNT(DISTINCT month_start) > 0
      THEN ROUND(SUM(monthly_revenue) / COUNT(DISTINCT month_start), 2)
      ELSE 0
    END AS avg_monthly_revenue
  FROM monthly_revenue
  GROUP BY customer_id
)

SELECT
  CAST(c.customer_id AS VARCHAR) AS customer_id,
  c.as_of_date,
  CAST(c.current_lifetime_revenue AS DECIMAL(18,2)) AS current_lifetime_revenue,
  CAST(c.current_order_count AS INTEGER) AS current_order_count,
  CAST(
    c.current_lifetime_revenue / GREATEST(c.current_order_count, 1)
    AS DECIMAL(18,2)
  ) AS avg_order_value,
  CAST(
    COALESCE(DATEDIFF('day', c.last_order_date, c.as_of_date), 0)
    AS INTEGER
  ) AS days_since_last_order,
  CAST(
    c.current_lifetime_revenue + 3 * COALESCE(a.avg_monthly_revenue, 0)
    AS DECIMAL(18,2)
  ) AS forecast_3m_revenue,
  CAST(
    c.current_lifetime_revenue + 6 * COALESCE(a.avg_monthly_revenue, 0)
    AS DECIMAL(18,2)
  ) AS forecast_6m_revenue,
  CAST(
    c.current_lifetime_revenue + 12 * COALESCE(a.avg_monthly_revenue, 0)
    AS DECIMAL(18,2)
  ) AS forecast_12m_revenue
FROM customer_metrics c
LEFT JOIN avg_monthly_revenue a ON c.customer_id = a.customer_id
EOF

cd /app/dbt_project
export DBT_PROFILES_DIR="/app/dbt_project"
dbt run --select rpt_customer_cltv_forecast


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% do run_query('CREATE SCHEMA IF NOT EXISTS "main"') %}
  {% set tables = [
    'rpt_customer_cltv_forecast',
    'int_sales__orders_enriched'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "main"."' ~ t ~ '" AS SELECT * FROM MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
