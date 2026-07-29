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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'customer_analytics'
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

PROJECT_DIR="${PROJECT_DIR:-/app/dbt_project}"
DB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"

echo ">>> Creating dbt project at ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"/models/{staging,intermediate,marts}

cat > "${PROJECT_DIR}/dbt_project.yml" << 'EOF'
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
EOF

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
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
      schema: customer_analytics
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
      schema: customer_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="${PROJECT_DIR}"

# Source definitions differ between DuckDB and Snowflake
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "${PROJECT_DIR}/models/staging/sources.yml" << 'EOF'
version: 2

sources:
  - name: customer_source
    database: "{{ env_var('SNOWFLAKE_DATABASE') }}"
    schema: CUSTOMER
    tables:
      - name: CUSTOMERS
  - name: orders_source
    database: "{{ env_var('SNOWFLAKE_DATABASE') }}"
    schema: ORDERS
    tables:
      - name: ORDERS
EOF
else
    cat > "${PROJECT_DIR}/models/staging/sources.yml" << 'EOF'
version: 2

sources:
  - name: orders_source
    schema: main
    tables:
      - name: customers
      - name: orders
EOF
fi

# Staging models - use Jinja to pick correct source per backend
cat > "${PROJECT_DIR}/models/staging/stg_customers.sql" << 'SQLEOF'
{{ config(materialized='view') }}

select
    TRIM(CAST(customer_id AS VARCHAR)) as customer_id,
    TRIM(CAST(customer_number AS VARCHAR)) as customer_number,
    TRIM(CAST(first_name AS VARCHAR)) as first_name,
    TRIM(CAST(last_name AS VARCHAR)) as last_name,
    TRIM(CAST(email AS VARCHAR)) as email,
    TRIM(CAST(status AS VARCHAR)) as status
{% if target.type == 'snowflake' %}
from {{ source('customer_source', 'CUSTOMERS') }}
{% else %}
from {{ source('orders_source', 'customers') }}
{% endif %}
SQLEOF

cat > "${PROJECT_DIR}/models/staging/stg_orders.sql" << 'SQLEOF'
{{ config(materialized='view') }}

select
    TRIM(CAST(order_id AS VARCHAR)) as order_id,
    TRIM(CAST(customer_id AS VARCHAR)) as customer_id,
    TRIM(CAST(order_number AS VARCHAR)) as order_number,
    UPPER(TRIM(CAST(status AS VARCHAR))) as status,
    grand_total,
    CAST(ordered_at AS TIMESTAMP) as ordered_at
{% if target.type == 'snowflake' %}
from {{ source('orders_source', 'ORDERS') }}
{% else %}
from {{ source('orders_source', 'orders') }}
{% endif %}
SQLEOF

# Intermediate model - cross-compatible SQL
cat > "${PROJECT_DIR}/models/intermediate/int_customer_order_metrics.sql" << 'EOF'
{{ config(materialized='view') }}

with valid_orders as (
    select
        customer_id,
        grand_total,
        ordered_at
    from {{ ref('stg_orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
)

select
    customer_id,
    count(*) as order_count,
    round(CAST(sum(grand_total) AS DOUBLE), 2) as total_spend,
    round(CAST(avg(grand_total) AS DOUBLE), 2) as avg_order_value,
    CAST(min(ordered_at) AS DATE) as first_order_date,
    CAST(max(ordered_at) AS DATE) as last_order_date,
    DATEDIFF('day', CAST(max(ordered_at) AS DATE), DATE '2024-12-01') as days_since_last_order
from valid_orders
group by customer_id
EOF

# Marts model - cross-compatible SQL
cat > "${PROJECT_DIR}/models/marts/dim_customer_tiers.sql" << 'EOF'
{{ config(materialized='table') }}

select
    c.customer_id,
    TRIM(c.first_name) || ' ' || TRIM(c.last_name) as customer_name,
    c.email,
    m.order_count,
    m.total_spend,
    m.avg_order_value,
    m.first_order_date,
    m.last_order_date,
    m.days_since_last_order,
    case
        when m.order_count >= 5 then 'VIP'
        when m.order_count >= 3 then 'Regular'
        else 'New'
    end as customer_tier
from {{ ref('stg_customers') }} c
inner join {{ ref('int_customer_order_metrics') }} m on c.customer_id = m.customer_id
order by c.customer_id
EOF

# Clean up existing tables/views (DuckDB only)
if [ "$DB_TYPE" = "duckdb" ]; then
    echo ">>> Cleaning up existing tables/views"
    duckdb "${DB_PATH}" << 'SQL'
DROP VIEW IF EXISTS customer_analytics.stg_customers;
DROP VIEW IF EXISTS customer_analytics.stg_orders;
DROP VIEW IF EXISTS customer_analytics.int_customer_order_metrics;
DROP TABLE IF EXISTS customer_analytics.dim_customer_tiers;
SQL
fi

echo ">>> Running dbt to build all models"
cd "${PROJECT_DIR}"
dbt deps || true
dbt run --select +dim_customer_tiers --full-refresh

echo ">>> Done. Output table: customer_analytics.dim_customer_tiers"
