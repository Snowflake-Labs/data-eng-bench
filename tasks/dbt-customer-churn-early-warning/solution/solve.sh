#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Create custom schema using admin role (agent role lacks CREATE SCHEMA privilege)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Creating custom schema using admin role..."
    python3 << 'CREATE_SCHEMA_PY'
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
schema = 'analytics'
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
db = os.environ['SNOWFLAKE_DATABASE']
try:
    cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema}")
    cur.execute(f"GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    print(f"Successfully created schema {schema} and granted permissions to {agent_role}")
except Exception as e:
    print(f"Warning: Failed to create schema {schema}: {e}")
conn.close()
CREATE_SCHEMA_PY
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Reference solution for Customer Churn Early Warning.
# Builds int_sales__orders_enriched from the reference project, then creates
# a standalone dbt project with the churn early warning mart.

PROJECT_DIR="${PROJECT_DIR:-/app/dbt_project}"
DB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi
echo "Using reference dbt project: $DBT_PROJECT_DIR"

# ============ STEP 1: Build reference model int_sales__orders_enriched ============
echo ">>> Building reference model int_sales__orders_enriched..."

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
      path: '${DB_PATH}'
      threads: 4
PROFILES
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
cd "$DBT_PROJECT_DIR"
dbt deps || echo "deps already installed"
dbt run --select int_sales__orders_enriched

# ============ STEP 2: Create standalone project ============
echo ">>> Setting up agent project at ${PROJECT_DIR}..."
mkdir -p "${PROJECT_DIR}/models/marts/customer"

cat > "${PROJECT_DIR}/dbt_project.yml" <<'YAML'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'
model-paths: ["models"]
YAML

# Create profiles.yml for the standalone project
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "${PROJECT_DIR}/profiles.yml" <<PROFILES
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
      schema: analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
else
    cat > "${PROJECT_DIR}/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DB_PATH}'
      schema: analytics
      threads: 4
PROFILES
fi

# ============ STEP 3: Write model SQL ============
# Use DB_TYPE branching for SQL compatibility differences
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "${PROJECT_DIR}/models/marts/customer/rpt_customer_churn_early_warning_fixed.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['customer', 'churn', 'early_warning']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}

WITH orders AS (
  SELECT
    customer_id,
    order_id,
    CAST(grand_total AS DECIMAL(18,2)) AS grand_total,
    CAST(ordered_at AS TIMESTAMP) AS ordered_at
  FROM {{ orders_rel }}
  WHERE customer_id IS NOT NULL
    AND ordered_at IS NOT NULL
),

as_of AS (
  SELECT MAX(ordered_at) AS as_of_ts FROM orders
),

agg AS (
  SELECT
    o.customer_id,
    MIN(CAST(o.ordered_at AS DATE)) AS first_order_date,
    MAX(CAST(o.ordered_at AS DATE)) AS last_order_date,
    COUNT(DISTINCT o.order_id) AS lifetime_orders,
    ROUND(SUM(o.grand_total), 2) AS lifetime_revenue,
    COUNT(DISTINCT CASE
      WHEN o.ordered_at >= DATEADD('day', -90, a.as_of_ts) THEN o.order_id
      ELSE NULL
    END) AS order_count_90d,
    a.as_of_ts
  FROM orders o
  CROSS JOIN as_of a
  GROUP BY o.customer_id, a.as_of_ts
),

scored AS (
  SELECT
    customer_id,
    first_order_date,
    last_order_date,
    lifetime_orders,
    CAST(lifetime_revenue AS DECIMAL(18,2)) AS lifetime_revenue,
    order_count_90d,
    CAST(DATEDIFF('day', last_order_date, CAST(as_of_ts AS DATE)) AS INTEGER) AS days_since_last_order,
    CAST(DATE_TRUNC('week', CAST(as_of_ts AS TIMESTAMP)) AS DATE) AS week_start
  FROM agg
)

SELECT
  customer_id,
  week_start,
  first_order_date,
  last_order_date,
  days_since_last_order,
  order_count_90d,
  lifetime_orders,
  lifetime_revenue,
  CASE
    WHEN days_since_last_order <= 30 THEN 'low'
    WHEN days_since_last_order <= 90 THEN 'medium'
    ELSE 'high'
  END AS churn_risk_tier
FROM scored
EOF
else
    cat > "${PROJECT_DIR}/models/marts/customer/rpt_customer_churn_early_warning_fixed.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['customer', 'churn', 'early_warning']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}

WITH orders AS (
  SELECT
    customer_id,
    order_id,
    CAST(grand_total AS DECIMAL(18,2)) AS grand_total,
    CAST(ordered_at AS TIMESTAMP) AS ordered_at
  FROM {{ orders_rel }}
  WHERE customer_id IS NOT NULL
    AND ordered_at IS NOT NULL
),

as_of AS (
  SELECT MAX(ordered_at) AS as_of_ts FROM orders
),

agg AS (
  SELECT
    o.customer_id,
    MIN(CAST(o.ordered_at AS DATE)) AS first_order_date,
    MAX(CAST(o.ordered_at AS DATE)) AS last_order_date,
    COUNT(DISTINCT o.order_id) AS lifetime_orders,
    ROUND(SUM(o.grand_total), 2) AS lifetime_revenue,
    COUNT(DISTINCT CASE
      WHEN o.ordered_at >= a.as_of_ts - INTERVAL '90 days' THEN o.order_id
      ELSE NULL
    END) AS order_count_90d,
    a.as_of_ts
  FROM orders o
  CROSS JOIN as_of a
  GROUP BY o.customer_id, a.as_of_ts
),

scored AS (
  SELECT
    customer_id,
    first_order_date,
    last_order_date,
    lifetime_orders,
    CAST(lifetime_revenue AS DECIMAL(18,2)) AS lifetime_revenue,
    order_count_90d,
    CAST(DATEDIFF('day', last_order_date, CAST(as_of_ts AS DATE)) AS INTEGER) AS days_since_last_order,
    CAST(date_trunc('week', CAST(as_of_ts AS TIMESTAMP)) AS DATE) AS week_start
  FROM agg
)

SELECT
  customer_id,
  week_start,
  first_order_date,
  last_order_date,
  days_since_last_order,
  order_count_90d,
  lifetime_orders,
  lifetime_revenue,
  CASE
    WHEN days_since_last_order <= 30 THEN 'low'
    WHEN days_since_last_order <= 90 THEN 'medium'
    ELSE 'high'
  END AS churn_risk_tier
FROM scored
EOF
fi

# ============ STEP 4: Clean up and run dbt ============
if [ "$DB_TYPE" = "duckdb" ]; then
    echo ">>> Cleaning up existing tables/views"
    duckdb "${DB_PATH}" << 'SQL'
DROP TABLE IF EXISTS analytics.rpt_customer_churn_early_warning_fixed;
DROP TABLE IF EXISTS ANALYTICS.rpt_customer_churn_early_warning_fixed;
DROP VIEW IF EXISTS analytics.rpt_customer_churn_early_warning_fixed;
DROP VIEW IF EXISTS ANALYTICS.rpt_customer_churn_early_warning_fixed;
SQL
fi

echo ">>> Running dbt to build the model"
cd "${PROJECT_DIR}"
export DBT_PROFILES_DIR="${PROJECT_DIR}"
dbt deps || true
dbt run --select rpt_customer_churn_early_warning_fixed --full-refresh

echo "Solution complete!"
