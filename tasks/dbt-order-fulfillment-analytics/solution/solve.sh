#!/bin/bash
# Solution script for dbt_order_fulfillment_analytics task

set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Create custom schemas using admin role (agent role lacks CREATE SCHEMA privilege)
if [ "${DB_TYPE:-duckdb}" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Creating custom schemas (staging, intermediate, marts) using admin role..."
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
agent_role = os.environ.get('SNOWFLAKE_AGENT_ROLE', os.environ.get('SNOWFLAKE_ROLE', ''))
db = os.environ['SNOWFLAKE_DATABASE']

# Grant CREATE SCHEMA on database to agent role
try:
    cur.execute(f"GRANT CREATE SCHEMA ON DATABASE {db} TO ROLE {agent_role}")
    print(f"Granted CREATE SCHEMA on {db} to {agent_role}")
except Exception as e:
    print(f"Warning: Could not grant CREATE SCHEMA: {e}")

for schema_name in ['staging', 'intermediate', 'marts']:
    try:
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}")
        cur.execute(f"GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
        cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
        cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
        cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
        cur.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
        print(f"Created schema {schema_name} and granted permissions to {agent_role}")
    except Exception as e:
        print(f"Warning: Failed to create/grant schema {schema_name}: {e}")

# Also grant on default schema
default_schema = os.environ.get('SNOWFLAKE_SCHEMA', 'PUBLIC')
try:
    cur.execute(f"GRANT USAGE ON SCHEMA {db}.{default_schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{default_schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{default_schema} TO ROLE {agent_role}")
except Exception as e:
    print(f"Warning: Could not grant on default schema {default_schema}: {e}")

conn.close()
CREATE_SCHEMA_PY
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

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# ============================================================
# OVERRIDE SCHEMA NAMING MACRO
# ============================================================
# Override the generate_schema_name macro to use custom schemas directly
# without prefixing them with the target schema name
mkdir -p "$DBT_PROJECT_DIR/macros/utils"
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- set target_name = target.name -%}

    {# If custom schema is provided, use it directly #}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}

{%- endmacro %}
EOF

# ============================================================
# STAGING MODELS - Add to models/staging/orders/
# ============================================================

mkdir -p "$DBT_PROJECT_DIR/models/staging/orders"

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_orders.sql" << 'EOF'
{{ config(materialized='view', schema='staging') }}

select
    ORDER_ID as order_id,
    ORDER_NUMBER as order_number,
    CUSTOMER_ID as customer_id,
    ORDER_TYPE as order_type,
    ORDER_SOURCE as order_source,
    CHANNEL_ID as channel_id,
    CURRENCY_CODE as currency_code,
    STATUS as status,
    PAYMENT_STATUS as payment_status,
    FULFILLMENT_STATUS as fulfillment_status,
    SUBTOTAL as subtotal,
    DISCOUNT_TOTAL as discount_total,
    SHIPPING_TOTAL as shipping_total,
    TAX_TOTAL as tax_total,
    GRAND_TOTAL as grand_total,
    CAST(ORDERED_AT AS TIMESTAMP) as ordered_at,
    CAST(SHIPPED_AT AS TIMESTAMP) as shipped_at,
    CAST(DELIVERED_AT AS TIMESTAMP) as delivered_at,
    CAST(CANCELLED_AT AS TIMESTAMP) as cancelled_at,
    WAREHOUSE_ID as warehouse_id,
    CARRIER_CODE as carrier_code,
    SERVICE_LEVEL as service_level,
    CREATED_AT as created_at,
    UPDATED_AT as updated_at
from {{ source('orders', 'ORDERS') }}
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_order_lines.sql" << 'EOF'
{{ config(materialized='view', schema='staging') }}

select
    ORDER_LINE_ID as order_line_id,
    ORDER_ID as order_id,
    LINE_NUMBER as line_number,
    VARIANT_ID as variant_id,
    PRODUCT_ID as product_id,
    SKU as sku,
    PRODUCT_NAME as product_name,
    QUANTITY_ORDERED as quantity_ordered,
    QUANTITY_SHIPPED as quantity_shipped,
    QUANTITY_RETURNED as quantity_returned,
    UNIT_PRICE as unit_price,
    DISCOUNT_AMOUNT as discount_amount,
    TAX_AMOUNT as tax_amount,
    LINE_TOTAL as line_total,
    STATUS as status,
    CREATED_AT as created_at,
    UPDATED_AT as updated_at
from {{ source('orders', 'ORDER_LINES') }}
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_shipments.sql" << 'EOF'
{{ config(materialized='view', schema='staging') }}

select
    SHIPMENT_ID as shipment_id,
    SHIPMENT_NUMBER as shipment_number,
    ORDER_ID as order_id,
    WAREHOUSE_ID as warehouse_id,
    CARRIER_ID as carrier_id,
    SHIPPING_METHOD_ID as shipping_method_id,
    TRACKING_NUMBER as tracking_number,
    STATUS as status,
    CAST(SHIPPED_AT AS TIMESTAMP) as shipped_at,
    CAST(DELIVERED_AT AS TIMESTAMP) as delivered_at,
    SHIPPING_COST as shipping_cost,
    WEIGHT as weight,
    CREATED_AT as created_at,
    UPDATED_AT as updated_at
from {{ source('orders', 'SHIPMENTS') }}
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_shipment_lines.sql" << 'EOF'
{{ config(materialized='view', schema='staging') }}

select
    SHIPMENT_LINE_ID as shipment_line_id,
    SHIPMENT_ID as shipment_id,
    ORDER_LINE_ID as order_line_id,
    QUANTITY_SHIPPED as quantity_shipped,
    CREATED_AT as created_at
from {{ source('orders', 'SHIPMENT_LINES') }}
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_order_status_history.sql" << 'EOF'
{{ config(materialized='view', schema='staging') }}

select
    HISTORY_ID as history_id,
    ORDER_ID as order_id,
    OLD_STATUS as old_status,
    NEW_STATUS as new_status,
    CHANGED_BY as changed_by,
    CHANGE_REASON as change_reason,
    NOTES as notes,
    CAST(CHANGED_AT AS TIMESTAMP) as changed_at
from {{ source('orders', 'ORDER_STATUS_HISTORY') }}
EOF

cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_returns.sql" << 'EOF'
{{ config(materialized='view', schema='staging') }}

select
    RETURN_ID as return_id,
    RETURN_NUMBER as return_number,
    ORDER_ID as order_id,
    CUSTOMER_ID as customer_id,
    STATUS as status,
    RETURN_TYPE as return_type,
    REFUND_METHOD as refund_method,
    REFUND_AMOUNT as refund_amount,
    CAST(REQUESTED_AT AS TIMESTAMP) as requested_at,
    CAST(RECEIVED_AT AS TIMESTAMP) as received_at,
    CAST(PROCESSED_AT AS TIMESTAMP) as processed_at,
    NOTES as notes,
    CREATED_AT as created_at,
    UPDATED_AT as updated_at
from {{ source('orders', 'RETURNS') }}
EOF

# ============================================================
# INTERMEDIATE MODELS - Add to models/intermediate/
# ============================================================

mkdir -p "$DBT_PROJECT_DIR/models/intermediate"

cat > "$DBT_PROJECT_DIR/models/intermediate/int_order_lifecycle.sql" << 'DBTEOF'
{{ config(materialized='table', schema='intermediate') }}

with orders as (
    select * from {{ ref('stg_orders') }}
),

status_history as (
    select * from {{ ref('stg_order_status_history') }}
),

shipments as (
    select * from {{ ref('stg_shipments') }}
),

first_status_change as (
    select
        order_id,
        min(changed_at) as first_status_change_at
    from status_history
    group by order_id
),

first_shipment as (
    select
        order_id,
        min(shipped_at) as first_shipped_at
    from shipments
    where shipped_at is not null
    group by order_id
),

status_change_counts as (
    select
        order_id,
        count(*) as status_change_count
    from status_history
    group by order_id
)

select
    o.order_id,
    o.order_number,
    o.customer_id,
    o.order_type,
    o.order_source,
    o.status,
    o.grand_total,
    o.ordered_at,
    fsc.first_status_change_at,
    case
        when o.ordered_at is not null and fs.first_shipped_at is not null
        then DATEDIFF('second', o.ordered_at, fs.first_shipped_at) / 3600.0
        else null
    end as time_to_first_ship_hours,
    case
        when o.ordered_at is not null and o.delivered_at is not null
        then DATEDIFF('second', o.ordered_at, o.delivered_at) / 3600.0
        else null
    end as time_to_delivery_hours,
    coalesce(scc.status_change_count, 0) as status_change_count
from orders o
left join first_status_change fsc on o.order_id = fsc.order_id
left join first_shipment fs on o.order_id = fs.order_id
left join status_change_counts scc on o.order_id = scc.order_id
DBTEOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_shipment_performance.sql" << 'DBTEOF'
{{ config(materialized='table', schema='intermediate') }}

with shipments as (
    select * from {{ ref('stg_shipments') }}
),

shipment_lines as (
    select * from {{ ref('stg_shipment_lines') }}
),

shipment_line_aggregates as (
    select
        shipment_id,
        count(*) as items_in_shipment,
        sum(quantity_shipped) as total_quantity_shipped
    from shipment_lines
    group by shipment_id
)

select
    s.shipment_id,
    s.shipment_number,
    s.order_id,
    s.warehouse_id,
    s.carrier_id,
    s.status,
    s.shipped_at,
    s.delivered_at,
    coalesce(sla.items_in_shipment, 0) as items_in_shipment,
    coalesce(sla.total_quantity_shipped, 0) as total_quantity_shipped,
    s.shipping_cost,
    case
        when s.shipped_at is not null and s.delivered_at is not null
        then DATEDIFF('second', s.shipped_at, s.delivered_at) / 3600.0
        else null
    end as transit_time_hours
from shipments s
left join shipment_line_aggregates sla on s.shipment_id = sla.shipment_id
DBTEOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_order_fulfillment_status.sql" << 'DBTEOF'
{{ config(materialized='table', schema='intermediate') }}

with orders as (
    select * from {{ ref('stg_orders') }}
),

order_lines as (
    select * from {{ ref('stg_order_lines') }}
),

order_line_aggregates as (
    select
        order_id,
        count(*) as total_lines,
        sum(quantity_ordered) as total_quantity_ordered,
        sum(quantity_shipped) as total_quantity_shipped,
        sum(quantity_returned) as total_quantity_returned
    from order_lines
    group by order_id
)

select
    o.order_id,
    o.order_number,
    o.ordered_at,
    coalesce(ola.total_lines, 0) as total_lines,
    coalesce(ola.total_quantity_ordered, 0) as total_quantity_ordered,
    coalesce(ola.total_quantity_shipped, 0) as total_quantity_shipped,
    coalesce(ola.total_quantity_returned, 0) as total_quantity_returned,
    case
        when coalesce(ola.total_quantity_ordered, 0) > 0
        then CAST(coalesce(ola.total_quantity_shipped, 0) AS DOUBLE) * 100.0 / CAST(ola.total_quantity_ordered AS DOUBLE)
        else 0
    end as fulfillment_pct,
    case
        when coalesce(ola.total_quantity_ordered, 0) > 0
             and coalesce(ola.total_quantity_shipped, 0) >= ola.total_quantity_ordered
        then 1
        else 0
    end as is_fully_fulfilled,
    case
        when coalesce(ola.total_quantity_shipped, 0) > 0
             and coalesce(ola.total_quantity_shipped, 0) < coalesce(ola.total_quantity_ordered, 0)
        then 1
        else 0
    end as is_partially_fulfilled
from orders o
left join order_line_aggregates ola on o.order_id = ola.order_id
DBTEOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_order_revenue_summary.sql" << 'DBTEOF'
{{ config(materialized='table', schema='intermediate') }}

with orders as (
    select * from {{ ref('stg_orders') }}
),

order_lines as (
    select * from {{ ref('stg_order_lines') }}
),

order_line_aggregates as (
    select
        order_id,
        count(*) as line_item_count,
        sum(line_total) as gross_revenue
    from order_lines
    group by order_id
)

select
    o.order_id,
    cast(o.ordered_at as date) as order_date,
    o.warehouse_id,
    ola.line_item_count,
    ola.gross_revenue,
    coalesce(o.shipping_total, 0) as shipping_revenue,
    ola.gross_revenue + coalesce(o.shipping_total, 0) as total_revenue
from orders o
inner join order_line_aggregates ola on o.order_id = ola.order_id
where o.status != 'CANCELLED'
  and o.ordered_at is not null
DBTEOF

# ============================================================
# MART MODELS - Add to models/marts/
# ============================================================

mkdir -p "$DBT_PROJECT_DIR/models/marts"

cat > "$DBT_PROJECT_DIR/models/marts/mart_fulfillment_metrics.sql" << 'DBTEOF'
{{ config(materialized='table', schema='marts') }}

with order_lifecycle as (
    select * from {{ ref('int_order_lifecycle') }}
),

order_fulfillment as (
    select * from {{ ref('int_order_fulfillment_status') }}
),

order_revenue as (
    select * from {{ ref('int_order_revenue_summary') }}
),

shipments as (
    select * from {{ ref('stg_shipments') }}
),

order_metrics as (
    select
        r.warehouse_id,
        r.order_date,
        o.order_id,
        r.total_revenue,
        f.is_fully_fulfilled,
        f.is_partially_fulfilled,
        o.time_to_first_ship_hours,
        o.time_to_delivery_hours
    from order_lifecycle o
    inner join order_revenue r on o.order_id = r.order_id
    left join order_fulfillment f on o.order_id = f.order_id
),

shipment_counts as (
    select
        warehouse_id,
        cast(shipped_at as date) as order_date,
        count(*) as total_shipments
    from shipments
    where shipped_at is not null
    group by warehouse_id, cast(shipped_at as date)
)

select
    om.warehouse_id,
    om.order_date,
    count(distinct om.order_id) as total_orders,
    sum(om.total_revenue) as total_order_value,
    coalesce(sc.total_shipments, 0) as total_shipments,
    sum(om.is_fully_fulfilled) as orders_fully_fulfilled,
    sum(om.is_partially_fulfilled) as orders_partially_fulfilled,
    case
        when count(distinct om.order_id) > 0
        then CAST(sum(om.is_fully_fulfilled) AS DOUBLE) * 100.0 / CAST(count(distinct om.order_id) AS DOUBLE)
        else 0
    end as fulfillment_rate,
    avg(om.time_to_first_ship_hours) as avg_time_to_ship_hours,
    avg(om.time_to_delivery_hours) as avg_time_to_delivery_hours
from order_metrics om
left join shipment_counts sc on om.warehouse_id = sc.warehouse_id and om.order_date = sc.order_date
group by om.warehouse_id, om.order_date, sc.total_shipments
DBTEOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_return_analysis.sql" << 'DBTEOF'
{{ config(materialized='table', schema='marts') }}

with returns as (
    select * from {{ ref('stg_returns') }}
)

select
    return_type,
    date_trunc('month', requested_at) as return_month,
    count(*) as total_returns,
    sum(refund_amount) as total_refund_amount,
    avg(refund_amount) as avg_refund_amount,
    sum(case when status = 'PROCESSED' then 1 else 0 end) as returns_processed,
    sum(case when status = 'REJECTED' then 1 else 0 end) as returns_rejected,
    case
        when count(*) > 0
        then CAST(sum(case when status = 'PROCESSED' then 1 else 0 end) AS DOUBLE) * 100.0 / CAST(count(*) AS DOUBLE)
        else 0
    end as processing_rate,
    avg(
        case
            when status = 'PROCESSED' and requested_at is not null and processed_at is not null
            then DATEDIFF('second', requested_at, processed_at) / 86400.0
            else null
        end
    ) as avg_processing_time_days
from returns
group by return_type, date_trunc('month', requested_at)
DBTEOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_carrier_performance.sql" << 'DBTEOF'
{{ config(materialized='table', schema='marts') }}

with shipment_performance as (
    select * from {{ ref('int_shipment_performance') }}
)

select
    carrier_id,
    count(*) as total_shipments,
    sum(case when status = 'DELIVERED' then 1 else 0 end) as shipments_delivered,
    sum(case when status = 'FAILED' then 1 else 0 end) as shipments_failed,
    sum(case when status = 'IN_TRANSIT' then 1 else 0 end) as in_transit_shipments,
    case
        when count(*) > 0
        then CAST(sum(case when status = 'DELIVERED' then 1 else 0 end) AS DOUBLE) * 100.0 / CAST(count(*) AS DOUBLE)
        else 0
    end as delivery_rate,
    case
        when count(*) > 0
        then CAST(sum(case when status = 'FAILED' then 1 else 0 end) AS DOUBLE) * 100.0 / CAST(count(*) AS DOUBLE)
        else 0
    end as failed_shipment_rate,
    sum(shipping_cost) as total_shipping_cost,
    avg(shipping_cost) as avg_shipping_cost,
    avg(
        case
            when status = 'DELIVERED' and transit_time_hours is not null
            then transit_time_hours
            else null
        end
    ) as avg_transit_time_hours_delivered_only,
    sum(
        case
            when status = 'DELIVERED' and transit_time_hours <= 120
            then 1
            else 0
        end
    ) as on_time_delivery_count
from shipment_performance
group by carrier_id
DBTEOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_order_status_flow.sql" << 'DBTEOF'
{{ config(materialized='table', schema='marts') }}

with status_history as (
    select * from {{ ref('stg_order_status_history') }}
),

status_transitions as (
    select
        old_status,
        new_status,
        order_id,
        changed_at
    from status_history
    where old_status is not null and new_status is not null
),

previous_changes as (
    select
        st.old_status,
        st.new_status,
        st.order_id,
        st.changed_at,
        lag(st.changed_at) over (partition by st.order_id order by st.changed_at) as prev_changed_at
    from status_transitions st
),

total_transitions as (
    select count(*) as total_count
    from status_transitions
)

select
    pc.old_status,
    pc.new_status,
    count(*) as transition_count,
    count(distinct pc.order_id) as unique_orders,
    avg(
        case
            when pc.prev_changed_at is not null
            then DATEDIFF('second', pc.prev_changed_at, pc.changed_at) / 3600.0
            else null
        end
    ) as avg_time_in_old_status_hours,
    case
        when tt.total_count > 0
        then CAST(count(*) AS DOUBLE) * 100.0 / CAST(tt.total_count AS DOUBLE)
        else 0
    end as pct_of_all_transitions
from previous_changes pc
cross join total_transitions tt
group by pc.old_status, pc.new_status, tt.total_count
DBTEOF

cat > "$DBT_PROJECT_DIR/models/marts/mart_daily_revenue.sql" << 'DBTEOF'
{{ config(materialized='table', schema='marts') }}

with order_revenue as (
    select * from {{ ref('int_order_revenue_summary') }}
)

select
    order_date,
    count(distinct order_id) as order_count,
    sum(line_item_count) as line_item_count,
    sum(gross_revenue) as gross_revenue,
    sum(shipping_revenue) as shipping_revenue,
    sum(total_revenue) as total_revenue,
    case
        when count(distinct order_id) > 0
        then sum(total_revenue) / CAST(count(distinct order_id) AS DOUBLE)
        else 0
    end as avg_order_value
from order_revenue
group by order_date
DBTEOF

# Run dbt - only build the models we created for this task
cd "$DBT_PROJECT_DIR"

# Install dbt package dependencies first
dbt deps

dbt run --select \
    stg_orders stg_order_lines stg_shipments stg_shipment_lines stg_order_status_history stg_returns \
    int_order_lifecycle int_shipment_performance int_order_fulfillment_status int_order_revenue_summary \
    mart_fulfillment_metrics mart_return_analysis mart_carrier_performance mart_order_status_flow mart_daily_revenue

dbt test --select \
    stg_orders stg_order_lines stg_shipments stg_shipment_lines stg_order_status_history stg_returns \
    int_order_lifecycle int_shipment_performance int_order_fulfillment_status int_order_revenue_summary \
    mart_fulfillment_metrics mart_return_analysis mart_carrier_performance mart_order_status_flow mart_daily_revenue

echo "Solution complete!"
