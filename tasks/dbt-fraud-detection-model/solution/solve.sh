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

# Pre-create fraud_analytics schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating fraud_analytics schema using admin role..."
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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
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
    for schema_name in ['FRAUD_ANALYTICS', '"fraud_analytics"']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
    print(f"Successfully pre-created fraud_analytics schema in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi

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

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create necessary directories
mkdir -p models/staging/fraud
mkdir -p models/marts/fraud
mkdir -p macros/utils

# Override generate_schema_name so custom schema is used directly (without target schema prefix)
cat > macros/utils/generate_schema_name.sql << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}
    {%- endif -%}
{%- endmacro %}
EOF

# Create sources.yml for staging models
cat > models/staging/fraud/_sources.yml << 'EOF'
version: 2

sources:
  - name: fraud_main
    schema: main
    tables:
      - name: orders
        identifier: orders
      - name: ORDER_LINES
        identifier: ORDER_LINES
      - name: ADDRESSES
        identifier: ADDRESSES
EOF

# Create staging model for orders (prefixed with stg_fd_ to avoid conflicts)
cat > models/staging/fraud/stg_fd_orders.sql << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(CAST(ORDER_ID AS VARCHAR)) as order_id,
    trim(CAST(CUSTOMER_ID AS VARCHAR)) as customer_id,
    {% if target.type == 'snowflake' %}
    CAST(ORDERED_AT AS TIMESTAMP) as ordered_at,
    {% else %}
    ORDERED_AT as ordered_at,
    {% endif %}
    round(CAST(GRAND_TOTAL AS NUMERIC(18,2)), 2) as grand_total,
    trim(CAST(STATUS AS VARCHAR)) as status,
    trim(CAST(BILLING_ADDRESS_ID AS VARCHAR)) as billing_address_id,
    trim(CAST(SHIPPING_ADDRESS_ID AS VARCHAR)) as shipping_address_id,
    CASE
        WHEN CHARGEBACK_FLAG IS NULL THEN false
        WHEN UPPER(CAST(CHARGEBACK_FLAG AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') THEN true
        ELSE false
    END as chargeback_flag,
    CASE
        WHEN IS_FIRST_ORDER IS NULL THEN false
        WHEN UPPER(CAST(IS_FIRST_ORDER AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') THEN true
        ELSE false
    END as is_first_order
from {% if target.type == 'snowflake' %}ORDERS.ORDERS{% else %}{{ source('fraud_main', 'orders') }}{% endif %}
SQLEOF

# Create staging model for order lines
cat > models/staging/fraud/stg_fd_order_lines.sql << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(CAST(ORDER_LINE_ID AS VARCHAR)) as order_line_id,
    trim(CAST(ORDER_ID AS VARCHAR)) as order_id,
    coalesce(CAST(QUANTITY_ORDERED AS INTEGER), 0) as quantity_ordered
from {% if target.type == 'snowflake' %}ORDERS.ORDER_LINES{% else %}{{ source('fraud_main', 'ORDER_LINES') }}{% endif %}
SQLEOF

# Create staging model for addresses
cat > models/staging/fraud/stg_fd_addresses.sql << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(CAST(ADDRESS_ID AS VARCHAR)) as address_id,
    trim(CAST(CUSTOMER_ID AS VARCHAR)) as customer_id,
    trim(CAST(STATE_PROVINCE AS VARCHAR)) as state_province
from {% if target.type == 'snowflake' %}RAW_SFDC.ADDRESSES{% else %}{{ source('fraud_main', 'ADDRESSES') }}{% endif %}
SQLEOF

# Create fraud_flagged_orders mart model
cat > models/marts/fraud/fraud_flagged_orders.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        schema='fraud_analytics'
    )
}}

/*
    Fraud Detection Model
    Identifies orders meeting any of these criteria:
    1. High Value: grand_total > 1500
    2. Bulk Order: total items > 5
    3. Velocity Fraud: 2+ orders same day by same customer
    4. Address Mismatch: billing state != shipping state
    5. First-Time High Value: first order AND grand_total > 500
    6. Risky Customer History: customer has prior chargeback
*/

with orders as (
    select * from {{ ref('stg_fd_orders') }}
),

order_lines as (
    select * from {{ ref('stg_fd_order_lines') }}
),

addresses as (
    select * from {{ ref('stg_fd_addresses') }}
),

-- Calculate total items per order
order_items_agg as (
    select
        order_id,
        sum(quantity_ordered) as total_items
    from order_lines
    group by order_id
),

-- Calculate same-day order count per customer using window function
orders_with_velocity as (
    select
        o.order_id,
        o.customer_id,
        o.ordered_at,
        o.grand_total,
        o.billing_address_id,
        o.shipping_address_id,
        o.chargeback_flag,
        o.is_first_order,
        count(*) over (
            partition by o.customer_id, CAST(o.ordered_at AS DATE)
        ) as orders_same_day
    from orders o
),

-- Identify customers with chargeback history (any chargeback)
customer_chargeback_history as (
    select distinct
        customer_id
    from orders
    where chargeback_flag = true
),

-- Join with addresses
orders_with_addresses as (
    select
        ov.order_id,
        ov.customer_id,
        ov.ordered_at,
        ov.grand_total,
        ov.orders_same_day,
        ov.chargeback_flag,
        ov.is_first_order,
        ba.state_province as billing_state,
        sa.state_province as shipping_state,
        case when ch.customer_id is not null then true else false end as has_chargeback_history
    from orders_with_velocity ov
    left join addresses ba on ov.billing_address_id = ba.address_id
    left join addresses sa on ov.shipping_address_id = sa.address_id
    left join customer_chargeback_history ch on ov.customer_id = ch.customer_id
),

-- Combine all data and calculate flags
fraud_analysis as (
    select
        oa.order_id,
        oa.customer_id,
        oa.ordered_at,
        oa.grand_total,
        coalesce(oi.total_items, 0) as total_items,
        oa.orders_same_day,
        oa.billing_state,
        oa.shipping_state,
        -- Fraud flags
        case when oa.grand_total > 1500 then true else false end as is_high_value,
        case when coalesce(oi.total_items, 0) > 5 then true else false end as is_bulk_order,
        case when oa.orders_same_day >= 2 then true else false end as is_velocity_fraud,
        case
            when oa.billing_state is null or oa.shipping_state is null then false
            else oa.billing_state != oa.shipping_state
        end as is_address_mismatch,
        -- First-time high value: first order AND grand_total > 500
        case
            when oa.is_first_order = true and oa.grand_total > 500 then true
            else false
        end as is_first_order_high_value,
        oa.has_chargeback_history
    from orders_with_addresses oa
    left join order_items_agg oi on oa.order_id = oi.order_id
),

-- Calculate fraud flags count and risk level
final as (
    select
        order_id,
        customer_id,
        ordered_at,
        grand_total,
        total_items,
        orders_same_day,
        billing_state,
        shipping_state,
        is_high_value,
        is_bulk_order,
        is_velocity_fraud,
        is_address_mismatch,
        is_first_order_high_value,
        has_chargeback_history,
        (case when is_high_value then 1 else 0 end +
         case when is_bulk_order then 1 else 0 end +
         case when is_velocity_fraud then 1 else 0 end +
         case when is_address_mismatch then 1 else 0 end +
         case when is_first_order_high_value then 1 else 0 end +
         case when has_chargeback_history then 1 else 0 end) as fraud_flags_count,
        case
            when (case when is_high_value then 1 else 0 end +
                  case when is_bulk_order then 1 else 0 end +
                  case when is_velocity_fraud then 1 else 0 end +
                  case when is_address_mismatch then 1 else 0 end +
                  case when is_first_order_high_value then 1 else 0 end +
                  case when has_chargeback_history then 1 else 0 end) >= 4 then 'CRITICAL'
            when (case when is_high_value then 1 else 0 end +
                  case when is_bulk_order then 1 else 0 end +
                  case when is_velocity_fraud then 1 else 0 end +
                  case when is_address_mismatch then 1 else 0 end +
                  case when is_first_order_high_value then 1 else 0 end +
                  case when has_chargeback_history then 1 else 0 end) = 3 then 'HIGH'
            when (case when is_high_value then 1 else 0 end +
                  case when is_bulk_order then 1 else 0 end +
                  case when is_velocity_fraud then 1 else 0 end +
                  case when is_address_mismatch then 1 else 0 end +
                  case when is_first_order_high_value then 1 else 0 end +
                  case when has_chargeback_history then 1 else 0 end) = 2 then 'MEDIUM'
            when (case when is_high_value then 1 else 0 end +
                  case when is_bulk_order then 1 else 0 end +
                  case when is_velocity_fraud then 1 else 0 end +
                  case when is_address_mismatch then 1 else 0 end +
                  case when is_first_order_high_value then 1 else 0 end +
                  case when has_chargeback_history then 1 else 0 end) = 1 then 'LOW'
            else 'NONE'
        end as fraud_risk_level
    from fraud_analysis
)

select * from final
order by order_id
SQLEOF

dbt deps
dbt run --select stg_fd_orders stg_fd_order_lines stg_fd_addresses fraud_flagged_orders

echo "Solution complete!"
