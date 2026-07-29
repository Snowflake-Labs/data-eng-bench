#!/bin/bash
set -euo pipefail

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

# Reference solution for Advanced Inventory Stockout Risk Analytics.
# Builds a multi-model dbt project with staging, intermediate, and mart layers
# implementing advanced stockout risk calculations with statistical measures.

PROJECT_DIR="${PROJECT_DIR:-/app/dbt_project}"
DB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"

echo ">>> Creating dbt project at ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"/models/{staging,intermediate,marts/operations}

cat > "${PROJECT_DIR}/dbt_project.yml" <<'YAML'
name: inventory_stockout_risk
version: 1.0.0
config-version: 2
profile: inventory_stockout_risk

model-paths: ["models"]
target-path: "target"
clean-targets: ["target", "dbt_packages"]

models:
  inventory_stockout_risk:
    staging:
      +materialized: view
    intermediate:
      +materialized: table
    marts:
      +materialized: table
YAML

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > "${PROJECT_DIR}/profiles.yml" <<YAML
inventory_stockout_risk:
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
YAML
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    cat > "${PROJECT_DIR}/profiles.yml" <<YAML
inventory_stockout_risk:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: ${DB_PATH}
      schema: analytics
      threads: 4
YAML
    echo "Configured DuckDB profile"
fi

# ============ STAGING MODEL ============
# SQL here is ANSI compatible for both DuckDB and Snowflake

cat > "${PROJECT_DIR}/models/staging/stg_orders_clean.sql" <<'SQL'
-- Clean and normalize order data
-- Filters out cancelled orders and invalid data

with orders as (
    select
        ORDER_ID as order_id,
        CAST(ORDERED_AT AS TIMESTAMP) as order_ts,
        CAST(ORDERED_AT AS DATE) as order_date
    from ORDERS.ORDERS
    where STATUS != 'CANCELLED'
      and ORDERED_AT is not null
),

order_lines as (
    select
        ORDER_ID as order_id,
        VARIANT_ID as variant_id,
        QUANTITY_ORDERED as quantity_ordered,
        UNIT_PRICE as unit_price
    from ORDERS.ORDER_LINES
    where QUANTITY_ORDERED > 0
)

select
    o.order_id,
    o.order_ts,
    o.order_date,
    ol.variant_id,
    ol.quantity_ordered,
    ol.unit_price
from orders o
inner join order_lines ol on o.order_id = ol.order_id
SQL

# ============ INTERMEDIATE MODEL 1: SALES VELOCITY ============
# Use ANSI SQL compatible with both DuckDB and Snowflake

cat > "${PROJECT_DIR}/models/intermediate/int_sales_velocity.sql" <<'SQL'
-- Calculate multi-period sales velocity metrics with statistical measures
-- One row per variant_id

with orders_clean as (
    select * from {{ ref('stg_orders_clean') }}
),

ref_date as (
    select MAX(order_date) as ref_date from {{ ref('stg_orders_clean') }}
),

-- Daily sales aggregation
daily_sales as (
    select
        variant_id,
        order_date,
        SUM(quantity_ordered) as daily_quantity
    from orders_clean
    cross join ref_date rd
    where order_date >= rd.ref_date - INTERVAL '90 days'
    group by variant_id, order_date
),

-- Calculate period averages
period_averages as (
    select
        ds.variant_id,
        -- 7-day average
        SUM(CASE WHEN ds.order_date >= rd.ref_date - INTERVAL '7 days' THEN ds.daily_quantity ELSE 0 END) / 7.0 as avg_daily_sales_7d,
        -- 30-day average
        SUM(CASE WHEN ds.order_date >= rd.ref_date - INTERVAL '30 days' THEN ds.daily_quantity ELSE 0 END) / 30.0 as avg_daily_sales_30d,
        -- 90-day average
        SUM(CASE WHEN ds.order_date >= rd.ref_date - INTERVAL '90 days' THEN ds.daily_quantity ELSE 0 END) / 90.0 as avg_daily_sales_90d
    from daily_sales ds
    cross join ref_date rd
    group by ds.variant_id
),

-- Calculate velocity ratio and trend
velocity_metrics as (
    select
        *,
        CASE
            WHEN avg_daily_sales_30d > 0
            THEN avg_daily_sales_7d / avg_daily_sales_30d
            ELSE NULL
        END as sales_velocity_ratio,
        CASE
            WHEN avg_daily_sales_30d IS NULL OR avg_daily_sales_30d = 0 THEN NULL
            WHEN (avg_daily_sales_7d / avg_daily_sales_30d) > 1.2 THEN 'ACCELERATING'
            WHEN (avg_daily_sales_7d / avg_daily_sales_30d) >= 0.8 THEN 'STABLE'
            ELSE 'DECELERATING'
        END as trend_direction
    from period_averages
),

-- Calculate statistical measures for 30-day period
stats_30d as (
    select
        ds.variant_id,
        CASE
            WHEN COUNT(*) >= 2
            THEN STDDEV_SAMP(ds.daily_quantity)
            ELSE NULL
        END as sales_volatility_30d,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY ds.daily_quantity) as p25_daily_sales_30d,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ds.daily_quantity) as median_daily_sales_30d,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY ds.daily_quantity) as p75_daily_sales_30d
    from daily_sales ds
    cross join ref_date rd
    where ds.order_date >= rd.ref_date - INTERVAL '30 days'
    group by ds.variant_id
),

-- Calculate volatility for 90-day period
stats_90d as (
    select
        ds.variant_id,
        CASE
            WHEN COUNT(*) >= 2
            THEN STDDEV_SAMP(ds.daily_quantity)
            ELSE NULL
        END as sales_volatility_90d
    from daily_sales ds
    cross join ref_date rd
    where ds.order_date >= rd.ref_date - INTERVAL '90 days'
    group by ds.variant_id
)

select
    v.variant_id,
    CASE WHEN v.avg_daily_sales_7d = 0 THEN NULL ELSE CAST(v.avg_daily_sales_7d AS DOUBLE PRECISION) END as avg_daily_sales_7d,
    CASE WHEN v.avg_daily_sales_30d = 0 THEN NULL ELSE CAST(v.avg_daily_sales_30d AS DOUBLE PRECISION) END as avg_daily_sales_30d,
    CASE WHEN v.avg_daily_sales_90d = 0 THEN NULL ELSE CAST(v.avg_daily_sales_90d AS DOUBLE PRECISION) END as avg_daily_sales_90d,
    CAST(v.sales_velocity_ratio AS DOUBLE PRECISION) as sales_velocity_ratio,
    v.trend_direction,
    CAST(s30.sales_volatility_30d AS DOUBLE PRECISION) as sales_volatility_30d,
    CAST(s90.sales_volatility_90d AS DOUBLE PRECISION) as sales_volatility_90d,
    CAST(s30.p25_daily_sales_30d AS DOUBLE PRECISION) as p25_daily_sales_30d,
    CAST(s30.p75_daily_sales_30d AS DOUBLE PRECISION) as p75_daily_sales_30d,
    CAST(s30.median_daily_sales_30d AS DOUBLE PRECISION) as median_daily_sales_30d
from velocity_metrics v
left join stats_30d s30 on v.variant_id = s30.variant_id
left join stats_90d s90 on v.variant_id = s90.variant_id
SQL

# ============ INTERMEDIATE MODEL 2: LEAD TIME CALCULATIONS ============
# Use conditional logic for DATEDIFF which differs between DuckDB and Snowflake

if [ "$DB_TYPE" = "snowflake" ]; then
    # Snowflake version - DATEDIFF uses unquoted day
    cat > "${PROJECT_DIR}/models/intermediate/int_lead_time_calculations.sql" <<'SQL'
-- Calculate effective lead times with fallback logic and statistics
-- One row per (variant_id, warehouse_id)

with inventory_levels as (
    select distinct
        VARIANT_ID as variant_id,
        WAREHOUSE_ID as warehouse_id
    from INVENTORY.INVENTORY_LEVELS
    where VARIANT_ID is not null and WAREHOUSE_ID is not null
),

-- Reorder rules
reorder_rules as (
    select
        VARIANT_ID as variant_id,
        WAREHOUSE_ID as warehouse_id,
        LEAD_TIME_DAYS,
        SAFETY_STOCK as safety_stock_days
    from (
        select *,
            ROW_NUMBER() OVER (PARTITION BY VARIANT_ID, WAREHOUSE_ID ORDER BY RULE_ID) as rn
        from INVENTORY.REORDER_RULES
    ) x
    where rn = 1
),

-- Reference date for time-based calculations
po_ref_date as (
    select MAX(CAST(ORDERED_AT AS DATE)) as ref_date
    from PROCUREMENT.PURCHASE_ORDERS
    where STATUS in ('RECEIVED', 'COMPLETED')
),

-- Lead time from purchase orders
lead_time_from_po as (
    select
        pol.VARIANT_ID as variant_id,
        po.WAREHOUSE_ID as warehouse_id,
        AVG(DATEDIFF(day, CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE))) as avg_lead_time,
        STDDEV_SAMP(DATEDIFF(day, CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE))) as std_dev_lead_time,
        MIN(DATEDIFF(day, CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE))) as min_lead_time,
        MAX(DATEDIFF(day, CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE))) as max_lead_time
    from PROCUREMENT.PURCHASE_ORDERS po
    inner join PROCUREMENT.PURCHASE_ORDER_LINES pol on po.PO_ID = pol.PO_ID
    left join (
        select PO_ID, MAX(RECEIVED_AT) as received_at
        from PROCUREMENT.PURCHASE_ORDER_RECEIPTS
        group by PO_ID
    ) rec on po.PO_ID = rec.PO_ID
    cross join po_ref_date prd
    where po.STATUS in ('RECEIVED', 'COMPLETED')
      and po.ORDERED_AT >= prd.ref_date - INTERVAL '180 days'
      and COALESCE(rec.received_at, po.EXPECTED_DATE) is not null
    group by pol.VARIANT_ID, po.WAREHOUSE_ID
    having COUNT(*) >= 1
)

select
    il.variant_id,
    il.warehouse_id,
    GREATEST(1.0, LEAST(365.0, COALESCE(CAST(rr.LEAD_TIME_DAYS AS DOUBLE PRECISION), CAST(ltp.avg_lead_time AS DOUBLE PRECISION), 14.0))) as lead_time_days,
    CAST(ltp.std_dev_lead_time AS DOUBLE PRECISION) as lead_time_std_dev,
    CAST(ltp.min_lead_time AS DOUBLE PRECISION) as lead_time_min,
    CAST(ltp.max_lead_time AS DOUBLE PRECISION) as lead_time_max,
    COALESCE(CAST(rr.safety_stock_days AS DOUBLE PRECISION), 7.0) as safety_stock_days,
    CAST(1.5 AS DOUBLE PRECISION) as reorder_point_multiplier
from inventory_levels il
left join reorder_rules rr
    on il.variant_id = rr.variant_id and il.warehouse_id = rr.warehouse_id
left join lead_time_from_po ltp
    on il.variant_id = ltp.variant_id and il.warehouse_id = ltp.warehouse_id
SQL
else
    # DuckDB version - DATEDIFF uses quoted 'day'
    cat > "${PROJECT_DIR}/models/intermediate/int_lead_time_calculations.sql" <<'SQL'
-- Calculate effective lead times with fallback logic and statistics
-- One row per (variant_id, warehouse_id)

with inventory_levels as (
    select distinct
        VARIANT_ID as variant_id,
        WAREHOUSE_ID as warehouse_id
    from INVENTORY.INVENTORY_LEVELS
    where VARIANT_ID is not null and WAREHOUSE_ID is not null
),

-- Reorder rules
reorder_rules as (
    select
        VARIANT_ID as variant_id,
        WAREHOUSE_ID as warehouse_id,
        LEAD_TIME_DAYS,
        SAFETY_STOCK as safety_stock_days
    from (
        select *,
            ROW_NUMBER() OVER (PARTITION BY VARIANT_ID, WAREHOUSE_ID ORDER BY RULE_ID) as rn
        from INVENTORY.REORDER_RULES
    ) x
    where rn = 1
),

-- Reference date for time-based calculations
po_ref_date as (
    select MAX(CAST(ORDERED_AT AS DATE)) as ref_date
    from PROCUREMENT.PURCHASE_ORDERS
    where STATUS in ('RECEIVED', 'COMPLETED')
),

-- Lead time from purchase orders
lead_time_from_po as (
    select
        pol.VARIANT_ID as variant_id,
        po.WAREHOUSE_ID as warehouse_id,
        AVG(DATEDIFF('day', CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE)))::DOUBLE as avg_lead_time,
        STDDEV_SAMP(DATEDIFF('day', CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE)))::DOUBLE as std_dev_lead_time,
        MIN(DATEDIFF('day', CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE)))::DOUBLE as min_lead_time,
        MAX(DATEDIFF('day', CAST(po.ORDERED_AT AS DATE), CAST(COALESCE(rec.received_at, po.EXPECTED_DATE) AS DATE)))::DOUBLE as max_lead_time
    from PROCUREMENT.PURCHASE_ORDERS po
    inner join PROCUREMENT.PURCHASE_ORDER_LINES pol on po.PO_ID = pol.PO_ID
    left join (
        select PO_ID, MAX(RECEIVED_AT) as received_at
        from PROCUREMENT.PURCHASE_ORDER_RECEIPTS
        group by PO_ID
    ) rec on po.PO_ID = rec.PO_ID
    cross join po_ref_date prd
    where po.STATUS in ('RECEIVED', 'COMPLETED')
      and po.ORDERED_AT >= prd.ref_date - INTERVAL '180 days'
      and COALESCE(rec.received_at, po.EXPECTED_DATE) is not null
    group by pol.VARIANT_ID, po.WAREHOUSE_ID
    having COUNT(*) >= 1
)

select
    il.variant_id,
    il.warehouse_id,
    GREATEST(1.0, LEAST(365.0, COALESCE(rr.LEAD_TIME_DAYS, ltp.avg_lead_time, 14.0)))::DOUBLE as lead_time_days,
    ltp.std_dev_lead_time as lead_time_std_dev,
    ltp.min_lead_time as lead_time_min,
    ltp.max_lead_time as lead_time_max,
    COALESCE(rr.safety_stock_days, 7.0)::DOUBLE as safety_stock_days,
    1.5::DOUBLE as reorder_point_multiplier
from inventory_levels il
left join reorder_rules rr
    on il.variant_id = rr.variant_id and il.warehouse_id = rr.warehouse_id
left join lead_time_from_po ltp
    on il.variant_id = ltp.variant_id and il.warehouse_id = ltp.warehouse_id
SQL
fi

# ============ MART MODEL ============
# Use conditional logic for type casting

if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "${PROJECT_DIR}/models/marts/operations/fct_stockout_risk.sql" <<'SQL'
-- Advanced Inventory Stockout Risk Fact Table
-- Final mart with comprehensive risk analysis

with inventory_levels as (
    select
        VARIANT_ID as variant_id,
        WAREHOUSE_ID as warehouse_id,
        QUANTITY_ON_HAND as quantity_on_hand,
        QUANTITY_AVAILABLE as quantity_available,
        COALESCE(QUANTITY_INCOMING, 0) as quantity_incoming
    from (
        select *,
            ROW_NUMBER() OVER (PARTITION BY VARIANT_ID, WAREHOUSE_ID ORDER BY VARIANT_ID, WAREHOUSE_ID) as rn
        from INVENTORY.INVENTORY_LEVELS
        where WAREHOUSE_ID is not null and VARIANT_ID is not null
    ) t
    where rn = 1
),

sales_velocity as (
    select * from {{ ref('int_sales_velocity') }}
),

lead_times as (
    select * from {{ ref('int_lead_time_calculations') }}
),

product_variants as (
    select
        VARIANT_ID as variant_id,
        PRODUCT_ID as product_id,
        SKU as sku
    from PRODUCT.PRODUCT_VARIANTS
),

products as (
    select
        PRODUCT_ID as product_id,
        PRODUCT_NAME as product_name
    from PRODUCT.PRODUCTS
),

warehouses as (
    select
        WAREHOUSE_ID as warehouse_id,
        WAREHOUSE_NAME as warehouse_name
    from INVENTORY.WAREHOUSES
),

-- Combine all data
inventory_with_metrics as (
    select
        il.*,
        sv.avg_daily_sales_7d,
        sv.avg_daily_sales_30d,
        sv.avg_daily_sales_90d,
        sv.sales_velocity_ratio,
        sv.trend_direction,
        sv.sales_volatility_30d,
        sv.sales_volatility_90d,
        sv.p25_daily_sales_30d,
        sv.p75_daily_sales_30d,
        sv.median_daily_sales_30d,
        lt.lead_time_days,
        lt.lead_time_std_dev,
        lt.lead_time_min,
        lt.lead_time_max,
        lt.safety_stock_days,
        lt.reorder_point_multiplier
    from inventory_levels il
    left join sales_velocity sv on il.variant_id = sv.variant_id
    left join lead_times lt on il.variant_id = lt.variant_id and il.warehouse_id = lt.warehouse_id
)

select
    COALESCE(w.warehouse_name, 'Unknown') as warehouse_name,
    COALESCE(p.product_name, 'Unknown') as product_name,
    COALESCE(pv.sku, 'Unknown') as sku,
    iwm.quantity_on_hand,
    iwm.quantity_available,
    iwm.quantity_incoming,
    iwm.avg_daily_sales_7d,
    iwm.avg_daily_sales_30d,
    iwm.avg_daily_sales_90d,
    iwm.sales_velocity_ratio,
    iwm.trend_direction,
    iwm.sales_volatility_30d,
    iwm.sales_volatility_90d,
    iwm.p25_daily_sales_30d,
    iwm.p75_daily_sales_30d,
    iwm.median_daily_sales_30d,
    iwm.lead_time_days,
    iwm.lead_time_std_dev,
    iwm.lead_time_min,
    iwm.lead_time_max,
    iwm.safety_stock_days,
    CAST((CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0
        THEN NULL
        ELSE iwm.safety_stock_days * iwm.avg_daily_sales_30d
    END) AS DOUBLE PRECISION) as safety_stock_quantity,
    iwm.reorder_point_multiplier,
    CAST((CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0
        THEN NULL
        ELSE (iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
            + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)
    END) AS DOUBLE PRECISION) as reorder_point,
    CAST((iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0)) AS DOUBLE PRECISION) as days_until_stockout,
    CAST((CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0 THEN NULL
        WHEN iwm.quantity_available < ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
            + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
        THEN (iwm.quantity_available - ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
            + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))) / iwm.avg_daily_sales_30d
        ELSE NULL
    END) AS DOUBLE PRECISION) as days_until_reorder_point,
    CASE
        -- NO_RISK: no sales history
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0 THEN 'NO_RISK'
        -- CRITICAL: multiple conditions
        WHEN (iwm.quantity_available <= (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= iwm.lead_time_days
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0))
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.3))
        THEN 'CRITICAL'
        -- HIGH: multiple conditions
        WHEN (iwm.quantity_available > (iwm.safety_stock_days * iwm.avg_daily_sales_30d)
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + iwm.safety_stock_days)
               AND iwm.trend_direction = 'ACCELERATING')
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0) + iwm.safety_stock_days)
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.2))
        THEN 'HIGH'
        -- MEDIUM: multiple conditions
        WHEN (iwm.quantity_available > ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)) * 1.5)
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days * 2)
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
        THEN 'MEDIUM'
        -- LOW: otherwise
        ELSE 'LOW'
    END as stockout_risk,
    CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0 THEN 'NO_ACTION'
        WHEN (iwm.quantity_available <= (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= iwm.lead_time_days
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0))
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.3))
        THEN 'URGENT_REORDER'
        WHEN (iwm.quantity_available > (iwm.safety_stock_days * iwm.avg_daily_sales_30d)
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + iwm.safety_stock_days)
               AND iwm.trend_direction = 'ACCELERATING')
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0) + iwm.safety_stock_days)
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.2))
        THEN 'REORDER_NOW'
        WHEN (iwm.quantity_available > ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)) * 1.5)
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days * 2)
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
        THEN 'PLAN_REORDER'
        ELSE 'MONITOR'
    END as recommended_action
from inventory_with_metrics iwm
left join product_variants pv on iwm.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
left join warehouses w on iwm.warehouse_id = w.warehouse_id
SQL
else
    cat > "${PROJECT_DIR}/models/marts/operations/fct_stockout_risk.sql" <<'SQL'
-- Advanced Inventory Stockout Risk Fact Table
-- Final mart with comprehensive risk analysis

with inventory_levels as (
    select
        VARIANT_ID as variant_id,
        WAREHOUSE_ID as warehouse_id,
        QUANTITY_ON_HAND as quantity_on_hand,
        QUANTITY_AVAILABLE as quantity_available,
        COALESCE(QUANTITY_INCOMING, 0) as quantity_incoming
    from (
        select *,
            ROW_NUMBER() OVER (PARTITION BY VARIANT_ID, WAREHOUSE_ID ORDER BY VARIANT_ID, WAREHOUSE_ID) as rn
        from INVENTORY.INVENTORY_LEVELS
        where WAREHOUSE_ID is not null and VARIANT_ID is not null
    ) t
    where rn = 1
),

sales_velocity as (
    select * from {{ ref('int_sales_velocity') }}
),

lead_times as (
    select * from {{ ref('int_lead_time_calculations') }}
),

product_variants as (
    select
        VARIANT_ID as variant_id,
        PRODUCT_ID as product_id,
        SKU as sku
    from PRODUCT.PRODUCT_VARIANTS
),

products as (
    select
        PRODUCT_ID as product_id,
        PRODUCT_NAME as product_name
    from PRODUCT.PRODUCTS
),

warehouses as (
    select
        WAREHOUSE_ID as warehouse_id,
        WAREHOUSE_NAME as warehouse_name
    from INVENTORY.WAREHOUSES
),

-- Combine all data
inventory_with_metrics as (
    select
        il.*,
        sv.avg_daily_sales_7d,
        sv.avg_daily_sales_30d,
        sv.avg_daily_sales_90d,
        sv.sales_velocity_ratio,
        sv.trend_direction,
        sv.sales_volatility_30d,
        sv.sales_volatility_90d,
        sv.p25_daily_sales_30d,
        sv.p75_daily_sales_30d,
        sv.median_daily_sales_30d,
        lt.lead_time_days,
        lt.lead_time_std_dev,
        lt.lead_time_min,
        lt.lead_time_max,
        lt.safety_stock_days,
        lt.reorder_point_multiplier
    from inventory_levels il
    left join sales_velocity sv on il.variant_id = sv.variant_id
    left join lead_times lt on il.variant_id = lt.variant_id and il.warehouse_id = lt.warehouse_id
)

select
    COALESCE(w.warehouse_name, 'Unknown') as warehouse_name,
    COALESCE(p.product_name, 'Unknown') as product_name,
    COALESCE(pv.sku, 'Unknown') as sku,
    iwm.quantity_on_hand,
    iwm.quantity_available,
    iwm.quantity_incoming,
    iwm.avg_daily_sales_7d,
    iwm.avg_daily_sales_30d,
    iwm.avg_daily_sales_90d,
    iwm.sales_velocity_ratio,
    iwm.trend_direction,
    iwm.sales_volatility_30d,
    iwm.sales_volatility_90d,
    iwm.p25_daily_sales_30d,
    iwm.p75_daily_sales_30d,
    iwm.median_daily_sales_30d,
    iwm.lead_time_days,
    iwm.lead_time_std_dev,
    iwm.lead_time_min,
    iwm.lead_time_max,
    iwm.safety_stock_days,
    (CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0
        THEN NULL
        ELSE iwm.safety_stock_days * iwm.avg_daily_sales_30d
    END)::DOUBLE as safety_stock_quantity,
    iwm.reorder_point_multiplier,
    (CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0
        THEN NULL
        ELSE (iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
            + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)
    END)::DOUBLE as reorder_point,
    (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0))::DOUBLE as days_until_stockout,
    (CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0 THEN NULL
        WHEN iwm.quantity_available < ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
            + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
        THEN (iwm.quantity_available - ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
            + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))) / iwm.avg_daily_sales_30d
        ELSE NULL
    END)::DOUBLE as days_until_reorder_point,
    CASE
        -- NO_RISK: no sales history
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0 THEN 'NO_RISK'
        -- CRITICAL: multiple conditions
        WHEN (iwm.quantity_available <= (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= iwm.lead_time_days
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0))
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.3))
        THEN 'CRITICAL'
        -- HIGH: multiple conditions
        WHEN (iwm.quantity_available > (iwm.safety_stock_days * iwm.avg_daily_sales_30d)
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + iwm.safety_stock_days)
               AND iwm.trend_direction = 'ACCELERATING')
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0) + iwm.safety_stock_days)
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.2))
        THEN 'HIGH'
        -- MEDIUM: multiple conditions
        WHEN (iwm.quantity_available > ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)) * 1.5)
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days * 2)
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
        THEN 'MEDIUM'
        -- LOW: otherwise
        ELSE 'LOW'
    END as stockout_risk,
    CASE
        WHEN iwm.avg_daily_sales_30d IS NULL OR iwm.avg_daily_sales_30d = 0 THEN 'NO_ACTION'
        WHEN (iwm.quantity_available <= (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= iwm.lead_time_days
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0))
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.3))
        THEN 'URGENT_REORDER'
        WHEN (iwm.quantity_available > (iwm.safety_stock_days * iwm.avg_daily_sales_30d)
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)))
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + iwm.safety_stock_days)
               AND iwm.trend_direction = 'ACCELERATING')
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days + COALESCE(iwm.lead_time_std_dev, 0) + iwm.safety_stock_days)
               AND iwm.sales_volatility_30d IS NOT NULL
               AND iwm.sales_volatility_30d > (iwm.avg_daily_sales_30d * 0.2))
        THEN 'REORDER_NOW'
        WHEN (iwm.quantity_available > ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d))
              AND iwm.quantity_available <= ((iwm.lead_time_days * iwm.avg_daily_sales_30d * iwm.reorder_point_multiplier)
                  + (iwm.safety_stock_days * iwm.avg_daily_sales_30d)) * 1.5)
           OR (iwm.quantity_available / NULLIF(iwm.avg_daily_sales_30d, 0) <= (iwm.lead_time_days * 2)
               AND iwm.trend_direction IN ('ACCELERATING', 'STABLE'))
        THEN 'PLAN_REORDER'
        ELSE 'MONITOR'
    END as recommended_action
from inventory_with_metrics iwm
left join product_variants pv on iwm.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
left join warehouses w on iwm.warehouse_id = w.warehouse_id
SQL
fi

if [ "$DB_TYPE" = "duckdb" ]; then
    echo ">>> Cleaning up existing tables/views"
    duckdb "${DB_PATH}" << 'SQL'
-- Drop views/tables in both case variations
DROP VIEW IF EXISTS analytics.stg_orders_clean;
DROP VIEW IF EXISTS ANALYTICS.stg_orders_clean;
DROP TABLE IF EXISTS analytics.int_sales_velocity;
DROP TABLE IF EXISTS ANALYTICS.int_sales_velocity;
DROP TABLE IF EXISTS analytics.int_lead_time_calculations;
DROP TABLE IF EXISTS ANALYTICS.int_lead_time_calculations;
DROP TABLE IF EXISTS analytics.fct_stockout_risk;
DROP TABLE IF EXISTS ANALYTICS.fct_stockout_risk;
SQL
fi

echo ">>> Running dbt to build all models"
cd "${PROJECT_DIR}"
export DBT_PROFILES_DIR="${PROJECT_DIR}"
dbt deps || true
dbt run --select +fct_stockout_risk --full-refresh

echo ">>> Done. Output table: analytics.fct_stockout_risk"
