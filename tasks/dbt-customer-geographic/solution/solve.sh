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
mkdir -p "${PROJECT_DIR}"/models/{staging,marts}

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
    marts:
      +materialized: table
EOF

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Pre-create the geographic_analytics schema using admin role
    # (agent role lacks CREATE SCHEMA privilege on the clone database)
    echo "Pre-creating GEOGRAPHIC_ANALYTICS schema with admin role..."
    python3 << 'PYEOF'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_pem = base64.b64decode(os.environ['SNOWFLAKE_PRIVATE_KEY'])
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
)

db = os.environ['SNOWFLAKE_DATABASE'].upper()
agent_role = os.environ.get('SNOWFLAKE_ROLE', '')
admin_role = os.environ.get('SNOWFLAKE_ADMIN_ROLE', '')

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=admin_role,
)
cur = conn.cursor()
cur.execute(f'GRANT CREATE SCHEMA ON DATABASE {db} TO ROLE {agent_role}')
print(f"Granted CREATE SCHEMA on {db} to {agent_role}")
cur.execute(f'USE DATABASE {db}')
cur.execute(f'CREATE SCHEMA IF NOT EXISTS GEOGRAPHIC_ANALYTICS')
print("Created schema GEOGRAPHIC_ANALYTICS")
if agent_role:
    cur.execute(f'GRANT USAGE ON SCHEMA {db}.GEOGRAPHIC_ANALYTICS TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.GEOGRAPHIC_ANALYTICS TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.GEOGRAPHIC_ANALYTICS TO ROLE {agent_role}')
    print(f"Granted permissions to {agent_role}")
conn.close()
PYEOF

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
      schema: geographic_analytics
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
      path: '${DB_PATH}'
      schema: geographic_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DB_PATH"
fi

mkdir -p "${PROJECT_DIR}/macros/utils"

# Override schema naming macro (both DuckDB and Snowflake)
# Forces all models into target.schema, preventing dbt from
# trying to create extra schemas (which would fail without CREATE SCHEMA privilege)
cat > "${PROJECT_DIR}/macros/utils/generate_schema_name.sql" << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is not none -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}

{%- endmacro %}
EOF

export DBT_PROFILES_DIR="${PROJECT_DIR}"

cat > "${PROJECT_DIR}/models/staging/sources.yml" << 'EOF'
version: 2

sources:
  - name: customer_schema
    schema: CUSTOMER
    tables:
      - name: CUSTOMER_ADDRESSES
  - name: orders_schema
    schema: ORDERS
    tables:
      - name: ORDERS
EOF

# Staging model: stg_customer_addresses
# is_default_shipping = 1 works on both DuckDB (boolean) and Snowflake (boolean/varchar)
cat > "${PROJECT_DIR}/models/staging/stg_customer_addresses.sql" << 'EOF'
{{ config(materialized='view') }}

select
    address_id,
    customer_id,
    state_province
from {{ source('customer_schema', 'CUSTOMER_ADDRESSES') }}
where is_default_shipping = 1
  and state_province is not null
EOF

# Staging model: stg_orders
cat > "${PROJECT_DIR}/models/staging/stg_orders.sql" << 'EOF'
{{ config(materialized='view') }}

select
    order_id,
    customer_id,
    coalesce(grand_total, 0) as grand_total
from {{ source('orders_schema', 'ORDERS') }}
where upper(status) in ('COMPLETED', 'DELIVERED', 'SHIPPED')
EOF

# Mart model: fct_state_customers
# Use CAST(... AS DOUBLE) instead of ::decimal for cross-DB compat
cat > "${PROJECT_DIR}/models/marts/fct_state_customers.sql" << 'EOF'
{{ config(materialized='table') }}

select
    ca.state_province,
    count(distinct ca.customer_id) as customer_count,
    count(distinct o.order_id) as order_count,
    round(coalesce(sum(o.grand_total), 0), 2) as total_revenue,
    round(coalesce(avg(o.grand_total), 0), 2) as avg_order_value,
    round(coalesce(sum(o.grand_total), 0) / nullif(count(distinct ca.customer_id), 0), 2) as revenue_per_customer,
    round(CAST(count(distinct o.order_id) AS DOUBLE) / nullif(count(distinct ca.customer_id), 0), 2) as orders_per_customer
from {{ ref('stg_customer_addresses') }} ca
left join {{ ref('stg_orders') }} o
    on ca.customer_id = o.customer_id
group by ca.state_province
order by total_revenue desc
EOF

cd "${PROJECT_DIR}"
dbt deps || true
dbt run
