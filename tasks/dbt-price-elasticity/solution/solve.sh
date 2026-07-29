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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"

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

    # DuckDB profile
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > profiles.yml <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: elasticity_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"

    # Create source definitions (DuckDB only)
    mkdir -p models/staging
    cat > models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: product
    schema: PRODUCT
    tables:
      - name: PRICE_HISTORY
  - name: orders
    schema: ORDERS
    tables:
      - name: ORDERS
      - name: ORDER_LINES
EOF
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Overwrite generate_schema_name macro so models land in the expected schema
mkdir -p "$DBT_PROJECT_DIR/macros/utils"
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema | trim }}
    {%- endif -%}
{%- endmacro %}
EOF

# Create directory structure
mkdir -p "$DBT_PROJECT_DIR/models/staging"
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts"

# ============================================================
# STAGING MODELS
# ============================================================

# Staging model for price history
cat > "$DBT_PROJECT_DIR/models/staging/stg_price_history.sql" << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

with source_data as (
    select
        PRODUCT_ID as product_id,
        cast(EFFECTIVE_DATE as date) as effective_date,
        PRICE as price
    from {{ source('product', 'PRICE_HISTORY') }}
    where PRICE > 0
      and PRODUCT_ID is not null
),

deduped as (
    select
        product_id,
        effective_date,
        price,
        row_number() over (partition by product_id, effective_date order by price) as rn
    from source_data
)

select
    product_id,
    effective_date,
    price
from deduped
where rn = 1
SQLEOF

# Staging model for order sales
cat > "$DBT_PROJECT_DIR/models/staging/stg_order_sales.sql" << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

with orders_data as (
    select
        ORDER_ID as order_id,
        cast(ORDERED_AT as date) as order_date,
        STATUS as status
    from {{ source('orders', 'ORDERS') }}
    where STATUS not in ('CANCELLED', 'RETURNED', 'FAILED')
),

order_lines_data as (
    select
        ORDER_ID as order_id,
        PRODUCT_ID as product_id,
        QUANTITY_ORDERED as quantity_ordered,
        UNIT_PRICE as unit_price
    from {{ source('orders', 'ORDER_LINES') }}
    where PRODUCT_ID is not null
      and QUANTITY_ORDERED > 0
      and UNIT_PRICE > 0
),

joined as (
    select
        ol.product_id,
        o.order_date,
        ol.quantity_ordered,
        ol.unit_price
    from order_lines_data ol
    inner join orders_data o on ol.order_id = o.order_id
)

select
    product_id,
    order_date,
    sum(quantity_ordered) as total_quantity,
    avg(unit_price) as avg_unit_price
from joined
group by product_id, order_date
SQLEOF

# ============================================================
# INTERMEDIATE MODELS
# ============================================================

# Intermediate model for monthly aggregations
# strftime is DuckDB-only; TO_VARCHAR is Snowflake-compatible
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "$DBT_PROJECT_DIR/models/intermediate/int_monthly_price_quantity.sql" << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

with monthly_sales as (
    select
        product_id,
        TO_VARCHAR(order_date, 'YYYY-MM') as year_month,
        sum(total_quantity) as total_quantity,
        avg(avg_unit_price) as avg_sales_price
    from {{ ref('stg_order_sales') }}
    group by product_id, TO_VARCHAR(order_date, 'YYYY-MM')
),

monthly_prices as (
    select
        product_id,
        TO_VARCHAR(effective_date, 'YYYY-MM') as year_month,
        avg(price) as avg_list_price
    from {{ ref('stg_price_history') }}
    group by product_id, TO_VARCHAR(effective_date, 'YYYY-MM')
),

-- Combine: use sales price if available, otherwise list price
combined as (
    select
        coalesce(s.product_id, p.product_id) as product_id,
        coalesce(s.year_month, p.year_month) as year_month,
        coalesce(s.avg_sales_price, p.avg_list_price) as avg_price,
        coalesce(s.total_quantity, 0) as total_quantity
    from monthly_sales s
    full outer join monthly_prices p
        on s.product_id = p.product_id
        and s.year_month = p.year_month
)

select
    product_id,
    year_month,
    avg_price,
    total_quantity
from combined
where product_id is not null
  and year_month is not null
  and avg_price > 0
  and total_quantity > 0
SQLEOF
else
    cat > "$DBT_PROJECT_DIR/models/intermediate/int_monthly_price_quantity.sql" << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

with monthly_sales as (
    select
        product_id,
        strftime(order_date, '%Y-%m') as year_month,
        sum(total_quantity) as total_quantity,
        avg(avg_unit_price) as avg_sales_price
    from {{ ref('stg_order_sales') }}
    group by product_id, strftime(order_date, '%Y-%m')
),

monthly_prices as (
    select
        product_id,
        strftime(effective_date, '%Y-%m') as year_month,
        avg(price) as avg_list_price
    from {{ ref('stg_price_history') }}
    group by product_id, strftime(effective_date, '%Y-%m')
),

-- Combine: use sales price if available, otherwise list price
combined as (
    select
        coalesce(s.product_id, p.product_id) as product_id,
        coalesce(s.year_month, p.year_month) as year_month,
        coalesce(s.avg_sales_price, p.avg_list_price) as avg_price,
        coalesce(s.total_quantity, 0) as total_quantity
    from monthly_sales s
    full outer join monthly_prices p
        on s.product_id = p.product_id
        and s.year_month = p.year_month
)

select
    product_id,
    year_month,
    avg_price,
    total_quantity
from combined
where product_id is not null
  and year_month is not null
  and avg_price > 0
  and total_quantity > 0
SQLEOF
fi

# Intermediate model for price changes (cross-DB compatible)
cat > "$DBT_PROJECT_DIR/models/intermediate/int_price_changes.sql" << 'SQLEOF'
{{
    config(
        materialized='view'
    )
}}

with base as (
    select
        product_id,
        year_month as period,
        avg_price as price,
        total_quantity as quantity
    from {{ ref('int_monthly_price_quantity') }}
),

with_lag as (
    select
        product_id,
        period,
        lag(period) over (partition by product_id order by period) as prev_period,
        price,
        lag(price) over (partition by product_id order by period) as prev_price,
        quantity,
        lag(quantity) over (partition by product_id order by period) as prev_quantity
    from base
),

with_changes as (
    select
        product_id,
        period,
        prev_period,
        price,
        prev_price,
        quantity,
        prev_quantity,
        -- Midpoint formula for percentage changes
        case
            when prev_price is not null and (price + prev_price) / 2 > 0
            then (CAST((price - prev_price) AS DOUBLE PRECISION) / CAST(((price + prev_price) / 2) AS DOUBLE PRECISION)) * 100
            else null
        end as price_pct_change,
        case
            when prev_quantity is not null and (quantity + prev_quantity) / 2 > 0
            then (CAST((quantity - prev_quantity) AS DOUBLE PRECISION) / CAST(((quantity + prev_quantity) / 2) AS DOUBLE PRECISION)) * 100
            else null
        end as quantity_pct_change
    from with_lag
    where prev_period is not null
)

select
    product_id,
    period,
    prev_period,
    price,
    prev_price,
    quantity,
    prev_quantity,
    price_pct_change,
    quantity_pct_change
from with_changes
where price_pct_change is not null
  and quantity_pct_change is not null
SQLEOF

# ============================================================
# MART MODEL
# ============================================================

cat > "$DBT_PROJECT_DIR/models/marts/product_elasticity.sql" << 'SQLEOF'
{{
    config(
        materialized='table'
    )
}}

with elasticity_calcs as (
    select
        product_id,
        period,
        price_pct_change,
        quantity_pct_change,
        case
            when abs(price_pct_change) > 0.001
            then CAST(quantity_pct_change AS DOUBLE PRECISION) / CAST(price_pct_change AS DOUBLE PRECISION)
            else null
        end as elasticity
    from {{ ref('int_price_changes') }}
),

valid_elasticities as (
    select
        product_id,
        elasticity
    from elasticity_calcs
    where elasticity is not null
),

product_stats as (
    select
        product_id,
        count(*) as num_observations,
        -- Cap elasticity between -10 and 10, then average
        avg(
            case
                when elasticity > 10 then 10
                when elasticity < -10 then -10
                else elasticity
            end
        ) as raw_elasticity
    from valid_elasticities
    group by product_id
    having count(*) >= 3
),

price_qty_stats as (
    select
        product_id,
        avg(avg_price) as avg_price,
        avg(total_quantity) as avg_quantity
    from {{ ref('int_monthly_price_quantity') }}
    group by product_id
),

final as (
    select
        ps.product_id,
        round(CAST(ps.raw_elasticity AS DOUBLE PRECISION), 4) as elasticity_coefficient,
        case
            when abs(ps.raw_elasticity - 1.0) <= 0.01 or abs(ps.raw_elasticity + 1.0) <= 0.01
            then 'unit_elastic'
            when abs(ps.raw_elasticity) > 1.0
            then 'elastic'
            else 'inelastic'
        end as elasticity_type,
        ps.num_observations,
        round(CAST(pqs.avg_price AS DOUBLE PRECISION), 2) as avg_price,
        round(CAST(pqs.avg_quantity AS DOUBLE PRECISION), 2) as avg_quantity
    from product_stats ps
    left join price_qty_stats pqs on ps.product_id = pqs.product_id
)

select
    product_id,
    elasticity_coefficient,
    elasticity_type,
    num_observations,
    avg_price,
    avg_quantity
from final
where elasticity_coefficient is not null
order by product_id
SQLEOF

# ============================================================
# Source definitions for Snowflake (if not present in pre-built project)
# ============================================================
if [ "$DB_TYPE" = "snowflake" ]; then
    # Create source definitions for the Snowflake project.
    # The pre-built project may already have 'product' and/or 'orders' sources
    # but without the specific tables we need (PRICE_HISTORY, ORDER_LINES).
    # Strategy: use Python/PyYAML to safely add missing tables to existing
    # sources, or create new source files if no existing source is found.
    mkdir -p "$DBT_PROJECT_DIR/models/staging"

    python3 - "$DBT_PROJECT_DIR" << 'PYEOF'
import sys, os, glob

project_dir = sys.argv[1]
models_dir = os.path.join(project_dir, "models")
staging_dir = os.path.join(models_dir, "staging")

import yaml  # dbt depends on pyyaml, so this is always available

def find_source(source_name):
    """Find YAML file containing a dbt source with exact name match.
    Returns (file_path, parsed_data, source_dict) or (None, None, None)."""
    for yml_path in sorted(glob.glob(os.path.join(models_dir, "**", "*.yml"), recursive=True)):
        try:
            with open(yml_path) as f:
                data = yaml.safe_load(f)
            if not isinstance(data, dict) or "sources" not in data:
                continue
            for src in data.get("sources", []):
                if isinstance(src, dict) and src.get("name") == source_name:
                    return yml_path, data, src
        except Exception:
            continue
    return None, None, None

def ensure_source_with_tables(source_name, schema_name, required_tables):
    """Ensure a dbt source exists with all required tables."""
    yml_path, data, src = find_source(source_name)
    if yml_path and src is not None:
        # Source exists - check which tables are missing
        existing_tables = set()
        for t in src.get("tables", []):
            if isinstance(t, dict):
                existing_tables.add(t.get("name"))
        missing = [t for t in required_tables if t not in existing_tables]
        if not missing:
            print(f"All tables {required_tables} already in {source_name} source ({yml_path})")
            return
        # Add missing tables
        if "tables" not in src:
            src["tables"] = []
        for tbl in missing:
            src["tables"].append({"name": tbl})
        with open(yml_path, "w") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)
        print(f"Added {missing} to {source_name} source in {yml_path}")
    else:
        # No existing source found - create a new source file
        new_path = os.path.join(staging_dir, f"_elasticity_{source_name}_source.yml")
        content = f"""version: 2

sources:
  - name: {source_name}
    schema: {schema_name}
    tables:
"""
        for tbl in required_tables:
            content += f"      - name: {tbl}\n"
        with open(new_path, "w") as f:
            f.write(content)
        print(f"Created new {source_name} source at {new_path}")

ensure_source_with_tables("product", "PRODUCT", ["PRICE_HISTORY"])
ensure_source_with_tables("orders", "ORDERS", ["ORDERS", "ORDER_LINES"])
PYEOF
fi

# ============================================================
# RUN DBT
# ============================================================

cd "$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps

echo "Running dbt models..."
dbt run --select stg_price_history stg_order_sales int_monthly_price_quantity int_price_changes product_elasticity --profiles-dir . --target dev

echo "Solution complete!"
