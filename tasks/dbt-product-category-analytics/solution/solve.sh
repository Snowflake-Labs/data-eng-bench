#!/bin/bash
# Solution script for dbt product category analytics task
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project
else
    DBT_PROJECT_DIR="/app/dbt_project"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # Create new dbt project
    mkdir -p "$DBT_PROJECT_DIR"
    cd "$DBT_PROJECT_DIR"

    cat > dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2

profile: 'dbt_project'

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

    # DuckDB profile (write to project dir so DBT_PROFILES_DIR works)
    cat > "$DBT_PROJECT_DIR/profiles.yml" << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: sales_analytics
EOF
    # Also write to ~/.dbt for fallback
    mkdir -p ~/.dbt
    cp "$DBT_PROJECT_DIR/profiles.yml" ~/.dbt/profiles.yml
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create directory structure
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts"

if [ "$DB_TYPE" = "snowflake" ]; then
    # ============================================================
    # SNOWFLAKE: Overwrite existing staging models at their subdirectory paths
    # to avoid duplicate model name conflicts. Use base project source names.
    # Do NOT create a separate sources.yml -- base project already has _sources.yml.
    # ============================================================

    cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_order_lines.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(order_line_id) as order_line_id,
    trim(order_id) as order_id,
    trim(product_id) as product_id,
    quantity_ordered,
    unit_price,
    coalesce(line_total, unit_price * quantity_ordered) as line_total,
    trim(status) as status
from {{ source('orders', 'ORDER_LINES') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/product/stg_products.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(product_id) as product_id,
    trim(product_code) as product_code,
    trim(product_name) as product_name,
    trim(primary_category_id) as category_id,
    coalesce(cost_price, 0) as cost_price
from {{ source('product', 'PRODUCTS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_categories.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(category_id) as category_id,
    trim(category_code) as category_code,
    trim(category_name) as category_name,
    category_level
from {{ source('product', 'PRODUCT_CATEGORIES') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/orders/stg_orders.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    upper(trim(status)) as status,
    grand_total,
    ordered_at
from {{ source('orders', 'ORDERS') }}
EOF

else
    # ============================================================
    # DUCKDB: Create staging models and sources from scratch
    # ============================================================

    mkdir -p "$DBT_PROJECT_DIR/models/staging"

    cat > "$DBT_PROJECT_DIR/models/staging/sources.yml" << 'EOF'
version: 2

sources:
  - name: orders_schema
    schema: ORDERS
    tables:
      - name: ORDER_LINES
  - name: product_schema
    schema: PRODUCT
    tables:
      - name: PRODUCTS
      - name: PRODUCT_CATEGORIES
  - name: main
    schema: main
    tables:
      - name: orders
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_order_lines.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(order_line_id) as order_line_id,
    trim(order_id) as order_id,
    trim(product_id) as product_id,
    quantity_ordered,
    unit_price,
    coalesce(line_total, unit_price * quantity_ordered) as line_total,
    trim(status) as status
from {{ source('orders_schema', 'ORDER_LINES') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_products.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(product_id) as product_id,
    trim(product_code) as product_code,
    trim(product_name) as product_name,
    trim(primary_category_id) as category_id,
    coalesce(cost_price, 0) as cost_price
from {{ source('product_schema', 'PRODUCTS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_categories.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(category_id) as category_id,
    trim(category_code) as category_code,
    trim(category_name) as category_name,
    category_level
from {{ source('product_schema', 'PRODUCT_CATEGORIES') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_orders.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    upper(trim(status)) as status,
    grand_total,
    ordered_at
from {{ source('main', 'orders') }}
EOF

fi

# ============================================================
# INTERMEDIATE MODEL
# ============================================================

cat > "$DBT_PROJECT_DIR/models/intermediate/int_product_sales.sql" << 'EOF'
{{ config(materialized='view') }}

select
    ol.order_line_id,
    ol.order_id,
    ol.product_id,
    p.product_name,
    c.category_id,
    c.category_name,
    c.category_level,
    ol.quantity_ordered,
    ol.unit_price,
    ol.line_total as revenue,
    p.cost_price * ol.quantity_ordered as cost
from {{ ref('stg_order_lines') }} ol
inner join {{ ref('stg_orders') }} o on ol.order_id = o.order_id
inner join {{ ref('stg_products') }} p on ol.product_id = p.product_id
inner join {{ ref('stg_categories') }} c on p.category_id = c.category_id
where o.status in ('COMPLETED', 'DELIVERED', 'SHIPPED')
EOF

# ============================================================
# MART MODEL
# ============================================================

cat > "$DBT_PROJECT_DIR/models/marts/fct_category_performance.sql" << 'EOF'
{{ config(materialized='table') }}

select
    category_id,
    category_name,
    category_level,
    count(distinct order_id) as total_orders,
    cast(sum(quantity_ordered) as integer) as total_units_sold,
    round(sum(revenue), 2) as total_revenue,
    round(sum(cost), 2) as total_cost,
    round(sum(revenue) - sum(cost), 2) as gross_profit,
    round((sum(revenue) - sum(cost)) / nullif(sum(revenue), 0), 4) as profit_margin,
    round(sum(revenue) / nullif(count(distinct order_id), 0), 2) as avg_order_value
from {{ ref('int_product_sales') }}
group by category_id, category_name, category_level
order by total_revenue desc
EOF

# ============================================================
# RUN DBT
# ============================================================

cd "$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps || true

echo "Running dbt models..."
if [ "$DB_TYPE" = "snowflake" ]; then
    dbt run --select stg_order_lines stg_products stg_categories stg_orders int_product_sales fct_category_performance
else
    dbt run
fi

echo "DBT run completed successfully!"
