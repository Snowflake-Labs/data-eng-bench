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

PROJECT_DIR="${PROJECT_DIR:-/app/dbt_project}"
DB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"

echo ">>> Creating dbt project at ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"/models/{staging,intermediate,marts}
mkdir -p "${PROJECT_DIR}"/macros/utils

# Create dbt_project.yml
cat > "${PROJECT_DIR}/dbt_project.yml" <<'YAML'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'

model-paths: ["models"]

models:
  dbt_project:
    staging:
      +materialized: view
    intermediate:
      +materialized: view
    marts:
      +materialized: table
YAML

# Override generate_schema_name macro to use custom schema
cat > "${PROJECT_DIR}/macros/utils/generate_schema_name.sql" <<'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    # Create custom schema using admin role
    if [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'fulfillment_analytics'
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

    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

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
      schema: fulfillment_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    cat > "${PROJECT_DIR}/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: ${DB_PATH}
      schema: fulfillment_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="${PROJECT_DIR}"

# ============ STAGING MODEL ============
# SQL is cross-compatible for both DuckDB and Snowflake

cat > "${PROJECT_DIR}/models/staging/stg_orders.sql" <<'SQL'
{{ config(materialized='view') }}

select
    trim(order_id) as order_id,
    trim(order_number) as order_number,
    trim(customer_id) as customer_id,
    upper(trim(order_type)) as order_type,
    upper(trim(status)) as status,
    coalesce(grand_total, 0) as grand_total,
    CAST(ordered_at AS TIMESTAMP) as ordered_at,
    CAST(shipped_at AS TIMESTAMP) as shipped_at,
    CAST(delivered_at AS TIMESTAMP) as delivered_at
from ORDERS.ORDERS
SQL

# ============ INTERMEDIATE MODEL 1: ORDER FULFILLMENT ============
# Use DATEDIFF for cross-DB compatibility

if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "${PROJECT_DIR}/models/intermediate/int_order_fulfillment.sql" <<'SQL'
{{ config(materialized='view') }}

select
    order_id,
    order_number,
    customer_id,
    order_type,
    status,
    grand_total,
    ordered_at,
    shipped_at,
    delivered_at,
    case when shipped_at is not null then 1 else 0 end as is_shipped,
    case when delivered_at is not null then 1 else 0 end as is_delivered,
    case when shipped_at is not null then
        CAST(DATEDIFF(day, CAST(ordered_at AS DATE), CAST(shipped_at AS DATE)) AS DOUBLE)
    else null end as processing_days,
    case when delivered_at is not null then
        CAST(DATEDIFF(day, CAST(ordered_at AS DATE), CAST(delivered_at AS DATE)) AS DOUBLE)
    else null end as delivery_days
from {{ ref('stg_orders') }}
where status in ('COMPLETED', 'DELIVERED', 'SHIPPED')
SQL
else
    cat > "${PROJECT_DIR}/models/intermediate/int_order_fulfillment.sql" <<'SQL'
{{ config(materialized='view') }}

select
    order_id,
    order_number,
    customer_id,
    order_type,
    status,
    grand_total,
    ordered_at,
    shipped_at,
    delivered_at,
    case when shipped_at is not null then 1 else 0 end as is_shipped,
    case when delivered_at is not null then 1 else 0 end as is_delivered,
    case when shipped_at is not null then
        CAST(DATEDIFF('day', CAST(ordered_at AS DATE), CAST(shipped_at AS DATE)) AS DOUBLE)
    else null end as processing_days,
    case when delivered_at is not null then
        CAST(DATEDIFF('day', CAST(ordered_at AS DATE), CAST(delivered_at AS DATE)) AS DOUBLE)
    else null end as delivery_days
from {{ ref('stg_orders') }}
where status in ('COMPLETED', 'DELIVERED', 'SHIPPED')
SQL
fi

# ============ INTERMEDIATE MODEL 2: ORDER TYPE AGGREGATES ============
# Cross-compatible SQL (uses CAST AS DOUBLE for division)

cat > "${PROJECT_DIR}/models/intermediate/int_order_type_aggregates.sql" <<'SQL'
{{ config(materialized='view') }}

select
    order_type,
    count(*) as total_orders,
    sum(is_shipped) as orders_shipped,
    sum(is_delivered) as orders_delivered,
    round(sum(grand_total), 2) as total_revenue,
    round(avg(grand_total), 2) as avg_order_value,
    coalesce(round(avg(processing_days), 2), 0) as avg_processing_days,
    coalesce(min(processing_days), 0) as min_processing_days,
    coalesce(max(processing_days), 0) as max_processing_days,
    coalesce(round(avg(delivery_days), 2), 0) as avg_delivery_days,
    coalesce(min(delivery_days), 0) as min_delivery_days,
    coalesce(max(delivery_days), 0) as max_delivery_days,
    round(CAST(100.0 * sum(is_shipped) AS DOUBLE) / CAST(count(*) AS DOUBLE), 4) as fulfillment_rate,
    round(CAST(100.0 * sum(is_delivered) AS DOUBLE) / CAST(count(*) AS DOUBLE), 4) as delivery_rate
from {{ ref('int_order_fulfillment') }}
group by order_type
SQL

# ============ INTERMEDIATE MODEL 3: ORDER TYPE RANKINGS ============
# Cross-compatible SQL

cat > "${PROJECT_DIR}/models/intermediate/int_order_type_rankings.sql" <<'SQL'
{{ config(materialized='view') }}

select
    order_type,
    total_orders,
    orders_shipped,
    orders_delivered,
    total_revenue,
    avg_order_value,
    avg_processing_days,
    min_processing_days,
    max_processing_days,
    avg_delivery_days,
    min_delivery_days,
    max_delivery_days,
    fulfillment_rate,
    delivery_rate,
    CAST(rank() over (order by total_orders desc) AS INTEGER) as volume_rank,
    CAST(rank() over (order by total_revenue desc) AS INTEGER) as revenue_rank,
    round(percent_rank() over (order by total_orders), 4) as volume_percentile,
    round(CAST(total_revenue AS DOUBLE) * 100.0 / CAST(sum(total_revenue) over () AS DOUBLE), 4) as revenue_share_pct
from {{ ref('int_order_type_aggregates') }}
SQL

# ============ FINAL MART MODEL ============
# Cross-compatible SQL

cat > "${PROJECT_DIR}/models/marts/fct_fulfillment_by_order_type.sql" <<'SQL'
{{ config(materialized='table') }}

select
    order_type,
    total_orders,
    orders_shipped,
    orders_delivered,
    fulfillment_rate,
    delivery_rate,
    avg_processing_days,
    min_processing_days,
    max_processing_days,
    avg_delivery_days,
    min_delivery_days,
    max_delivery_days,
    total_revenue,
    avg_order_value,
    volume_rank,
    revenue_rank,
    volume_percentile,
    revenue_share_pct,
    round((fulfillment_rate / 100.0 * 0.4) + (delivery_rate / 100.0 * 0.4) + ((1.0 / (avg_processing_days + 1)) * 0.2), 4) as efficiency_score,
    case
        when volume_percentile >= 0.66 then 'High Performance'
        when volume_percentile >= 0.33 then 'Medium Performance'
        else 'Low Performance'
    end as performance_tier,
    case
        when fulfillment_rate >= 90 then 'Excellent'
        when fulfillment_rate >= 70 then 'Good'
        when fulfillment_rate >= 50 then 'Average'
        else 'Poor'
    end as fulfillment_grade
from {{ ref('int_order_type_rankings') }}
order by total_orders desc
SQL

# Clean up conflicting relations (DuckDB only)
if [ "$DB_TYPE" = "duckdb" ]; then
    echo ">>> Cleaning up existing tables/views"
    duckdb "${DB_PATH}" << 'CLEANUP_SQL'
DROP VIEW IF EXISTS fulfillment_analytics.stg_orders;
DROP VIEW IF EXISTS fulfillment_analytics.int_order_fulfillment;
DROP VIEW IF EXISTS fulfillment_analytics.int_order_type_aggregates;
DROP VIEW IF EXISTS fulfillment_analytics.int_order_type_rankings;
DROP TABLE IF EXISTS fulfillment_analytics.fct_fulfillment_by_order_type;
CLEANUP_SQL
fi

echo ">>> Running dbt to build all models"
cd "${PROJECT_DIR}"
dbt deps || true
dbt run --select +fct_fulfillment_by_order_type --full-refresh

echo ">>> Done. Output table: fulfillment_analytics.fct_fulfillment_by_order_type"
