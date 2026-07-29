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

# Set reference dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    REF_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    REF_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi

echo "Using reference dbt project: $REF_PROJECT_DIR"

# ---- Step 1: Build required staging models from the reference project ----
echo "Preparing reference models..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile for reference project
    cat > "$REF_PROJECT_DIR/profiles.yml" <<PROFILES
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
    echo "Configured Snowflake profile for reference project"
else
    # DuckDB profile for reference project
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$REF_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      threads: 4
PROFILES
    echo "Configured DuckDB profile for reference project"
fi

cd "$REF_PROJECT_DIR"
export DBT_PROFILES_DIR="$REF_PROJECT_DIR"
dbt deps || echo "deps already installed"
dbt run --select stg_orders__order_lines stg_orders__orders stg_inventory__inventory_levels stg_product__product_variants stg_product__products

# ---- Step 2: Set up agent project ----
echo "Setting up agent project..."
cd /app
mkdir -p dbt_project/models/marts/inventory

# Profile for the agent project
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
      threads: 4
PROFILES
fi

cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'
model-paths: ["models"]
EOF

cat > dbt_project/models/marts/inventory/rpt_inventory_turnover_analysis.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        tags=['inventory', 'turnover', 'analytics']
    )
}}

{% set ol_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_orders__order_lines') %}
{% set o_rel  = adapter.get_relation(database=target.database, schema='main', identifier='stg_orders__orders') %}
{% set inv_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_inventory__inventory_levels') %}
{% set pv_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_product__product_variants') %}
{% set p_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_product__products') %}

WITH ref_date AS (
  SELECT MAX(CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE)) AS max_date
  FROM {{ o_rel }} o
  WHERE o.fulfillment_status = 'FULFILLED'
    AND COALESCE(o.shipped_at, o.delivered_at) IS NOT NULL
),

fulfilled_orders AS (
  SELECT
    o.order_id,
    CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) AS fulfilled_date
  FROM {{ o_rel }} o
  CROSS JOIN ref_date rd
  WHERE o.fulfillment_status = 'FULFILLED'
    AND COALESCE(o.shipped_at, o.delivered_at) IS NOT NULL
    {% if target.type == 'snowflake' %}
    AND CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) >= DATEADD(day, -180, rd.max_date)
    {% else %}
    AND CAST(COALESCE(o.shipped_at, o.delivered_at) AS DATE) >= rd.max_date - INTERVAL 180 DAY
    {% endif %}
),

period_bounds AS (
  SELECT
    COALESCE(MAX(fo.fulfilled_date), rd.max_date) AS period_end,
    {% if target.type == 'snowflake' %}
    COALESCE(MIN(fo.fulfilled_date), DATEADD(day, -180, rd.max_date)) AS period_start,
    COALESCE(DATEDIFF(day, MIN(fo.fulfilled_date), MAX(fo.fulfilled_date)) + 1, 180) AS period_days
    {% else %}
    COALESCE(MIN(fo.fulfilled_date), rd.max_date - INTERVAL 180 DAY) AS period_start,
    COALESCE(CAST(MAX(fo.fulfilled_date) - MIN(fo.fulfilled_date) AS INTEGER) + 1, 180) AS period_days
    {% endif %}
  FROM fulfilled_orders fo
  CROSS JOIN ref_date rd
  GROUP BY rd.max_date
),

windowed_orders AS (
  SELECT fo.order_id, fo.fulfilled_date
  FROM fulfilled_orders fo
  CROSS JOIN period_bounds pb
  {% if target.type == 'snowflake' %}
  WHERE fo.fulfilled_date >= DATEADD(day, -180, pb.period_end)
  {% else %}
  WHERE fo.fulfilled_date >= pb.period_end - INTERVAL 180 DAY
  {% endif %}
    AND fo.fulfilled_date <= pb.period_end
),

sales_by_sku_warehouse AS (
  SELECT
    pv.sku,
    il.warehouse_id,
    SUM(COALESCE(ol.quantity_ordered, 0)) AS total_units_sold
  FROM {{ ol_rel }} ol
  JOIN windowed_orders wo ON ol.order_id = wo.order_id
  JOIN {{ pv_rel }} pv ON ol.variant_id = pv.variant_id
  JOIN {{ inv_rel }} il ON pv.variant_id = il.variant_id
  WHERE pv.sku IS NOT NULL
    AND il.warehouse_id IS NOT NULL
  GROUP BY 1, 2
),

inventory_snapshots AS (
  SELECT
    pv.sku,
    il.warehouse_id,
    CAST(COALESCE(il.updated_at, il.created_at) AS DATE) AS snapshot_date,
    COALESCE(il.quantity_on_hand, 0) AS quantity_on_hand
  FROM {{ inv_rel }} il
  JOIN {{ pv_rel }} pv ON il.variant_id = pv.variant_id
  WHERE pv.sku IS NOT NULL
    AND il.warehouse_id IS NOT NULL
),

inventory_with_period AS (
  SELECT
    inv.*,
    pb.period_end,
    pb.period_start
  FROM inventory_snapshots inv
  CROSS JOIN period_bounds pb
),

inventory_in_period AS (
  SELECT
    sku,
    warehouse_id,
    AVG(quantity_on_hand) AS avg_inventory_on_hand
  FROM inventory_with_period
  WHERE snapshot_date >= period_start
    AND snapshot_date <= period_end
  GROUP BY 1, 2
),

inventory_latest AS (
  SELECT
    sku,
    warehouse_id,
    quantity_on_hand,
    ROW_NUMBER() OVER (PARTITION BY sku, warehouse_id ORDER BY snapshot_date DESC) AS rn
  FROM inventory_snapshots
  WHERE snapshot_date <= (SELECT MAX(period_end) FROM period_bounds)
),

inventory_current AS (
  SELECT
    sku,
    warehouse_id,
    quantity_on_hand AS current_quantity_on_hand
  FROM inventory_latest
  WHERE rn = 1
),

inventory_fallback AS (
  SELECT
    iip.sku,
    iip.warehouse_id,
    COALESCE(iip.avg_inventory_on_hand, 0) AS avg_inventory_on_hand,
    COALESCE(ic.current_quantity_on_hand, 0) AS current_quantity_on_hand
  FROM inventory_in_period iip
  FULL OUTER JOIN inventory_current ic
    ON iip.sku = ic.sku AND iip.warehouse_id = ic.warehouse_id
),

inventory_with_fallback AS (
  SELECT
    COALESCE(ifb.sku, ic.sku) AS sku,
    COALESCE(ifb.warehouse_id, ic.warehouse_id) AS warehouse_id,
    COALESCE(ifb.avg_inventory_on_hand, ic.current_quantity_on_hand, 0) AS avg_inventory_on_hand,
    COALESCE(ifb.current_quantity_on_hand, ic.current_quantity_on_hand, 0) AS current_quantity_on_hand
  FROM inventory_fallback ifb
  FULL OUTER JOIN inventory_current ic
    ON ifb.sku = ic.sku AND ifb.warehouse_id = ic.warehouse_id
),

product_categories AS (
  SELECT DISTINCT
    pv.sku,
    COALESCE(p.product_type, p.primary_category_id, 'UNKNOWN') AS product_category
  FROM {{ pv_rel }} pv
  LEFT JOIN {{ p_rel }} p ON pv.product_id = p.product_id
  WHERE pv.sku IS NOT NULL
),

combined_base AS (
  SELECT
    COALESCE(s.sku, i.sku) AS sku,
    COALESCE(s.warehouse_id, i.warehouse_id) AS warehouse_id,
    COALESCE(s.total_units_sold, 0) AS total_units_sold,
    COALESCE(i.avg_inventory_on_hand, 0) AS avg_inventory_on_hand,
    COALESCE(i.current_quantity_on_hand, 0) AS current_quantity_on_hand,
    COALESCE(pc.product_category, 'UNKNOWN') AS product_category
  FROM sales_by_sku_warehouse s
  FULL OUTER JOIN inventory_with_fallback i
    ON s.sku = i.sku AND s.warehouse_id = i.warehouse_id
  LEFT JOIN product_categories pc
    ON COALESCE(s.sku, i.sku) = pc.sku
),

with_period AS (
  SELECT
    cb.*,
    pb.period_days AS analysis_period_days
  FROM combined_base cb
  CROSS JOIN period_bounds pb
),

with_metrics AS (
  SELECT
    sku,
    warehouse_id,
    product_category,
    analysis_period_days,
    CAST(total_units_sold AS INTEGER) AS total_units_sold,
    CAST(avg_inventory_on_hand AS DECIMAL(18,2)) AS avg_inventory_on_hand,
    CASE
      WHEN total_units_sold = 0 OR total_units_sold IS NULL THEN CAST(0 AS DECIMAL(18,4))
      WHEN avg_inventory_on_hand = 0 OR avg_inventory_on_hand IS NULL THEN NULL
      ELSE CAST(total_units_sold AS DECIMAL(18,4)) / NULLIF(avg_inventory_on_hand, 0)
    END AS inventory_turnover_ratio,
    CASE
      WHEN total_units_sold = 0 OR total_units_sold IS NULL THEN NULL
      WHEN avg_inventory_on_hand = 0 OR avg_inventory_on_hand IS NULL THEN CAST(0 AS DECIMAL(18,2))
      ELSE CAST((avg_inventory_on_hand * analysis_period_days) AS DECIMAL(18,2)) / NULLIF(total_units_sold, 0)
    END AS days_of_supply,
    CAST(current_quantity_on_hand AS INTEGER) AS current_quantity_on_hand,
    CASE
      WHEN current_quantity_on_hand = 0 THEN CAST(0 AS DECIMAL(18,2))
      WHEN total_units_sold = 0 OR total_units_sold IS NULL THEN NULL
      ELSE CAST(current_quantity_on_hand AS DECIMAL(18,2)) / NULLIF((CAST(total_units_sold AS FLOAT) / CAST(analysis_period_days AS FLOAT)), 0)
    END AS estimated_days_until_stockout
  FROM with_period
),

with_velocity_class AS (
  SELECT
    sku,
    warehouse_id,
    product_category,
    analysis_period_days,
    total_units_sold,
    avg_inventory_on_hand,
    inventory_turnover_ratio,
    days_of_supply,
    current_quantity_on_hand,
    estimated_days_until_stockout,
    CASE
      WHEN inventory_turnover_ratio >= 12.0 THEN 'FAST'
      WHEN inventory_turnover_ratio >= 4.0 THEN 'MEDIUM'
      WHEN inventory_turnover_ratio >= 1.0 THEN 'SLOW'
      ELSE 'STAGNANT'
    END AS turnover_velocity_class
  FROM with_metrics
)

SELECT
  sku,
  warehouse_id,
  product_category,
  analysis_period_days,
  total_units_sold,
  avg_inventory_on_hand,
  CASE
    WHEN total_units_sold = 0 THEN CAST(0 AS DECIMAL(18,4))
    ELSE CAST(inventory_turnover_ratio AS DECIMAL(18,4))
  END AS inventory_turnover_ratio,
  CASE
    WHEN total_units_sold = 0 THEN CAST(NULL AS DECIMAL(18,2))
    ELSE CAST(days_of_supply AS DECIMAL(18,2))
  END AS days_of_supply,
  turnover_velocity_class,
  current_quantity_on_hand,
  CASE
    WHEN total_units_sold = 0 THEN CAST(NULL AS DECIMAL(18,2))
    ELSE CAST(estimated_days_until_stockout AS DECIMAL(18,2))
  END AS estimated_days_until_stockout
FROM with_velocity_class
WHERE sku IS NOT NULL
  AND warehouse_id IS NOT NULL
SQLEOF

cd /app/dbt_project
export DBT_PROFILES_DIR="/app/dbt_project"
dbt run --select rpt_inventory_turnover_analysis

echo "Solution complete!"
