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

cd "$DBT_PROJECT_DIR"

# For Snowflake: override generate_schema_name to just use the default schema
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p macros/utils
    cat > macros/utils/generate_schema_name.sql << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {{ default_schema }}
{%- endmacro %}
GENMACRO
fi

# Install dependencies first
dbt deps

# Create directories for models
mkdir -p models/marts/inventory

# =============================================================================
# Model 1: stg_fifo_transactions.sql (cross-compatible)
# =============================================================================
cat > models/marts/inventory/stg_fifo_transactions.sql << 'EOF'
{{
    config(
        materialized='view',
        schema='inventory_analytics'
    )
}}

select
    transaction_id,
    warehouse_id,
    variant_id,
    transaction_type,
    transaction_timestamp,
    transaction_date,
    abs(quantity) as quantity,
    coalesce(unit_cost, 0) as unit_cost,
    row_number() over (
        partition by warehouse_id, variant_id, transaction_type
        order by transaction_timestamp, transaction_id
    ) as row_num
from {{ source('inventory', 'INVENTORY_TRANSACTIONS') }}
where transaction_type in ('RECEIPT', 'PICK')
EOF

# =============================================================================
# Model 2: int_receipt_layers.sql (cross-compatible using DATEDIFF)
# =============================================================================
cat > models/marts/inventory/int_receipt_layers.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with receipts as (
    select
        transaction_id as receipt_id,
        warehouse_id,
        variant_id,
        transaction_timestamp as receipt_timestamp,
        transaction_date as receipt_date,
        quantity as receipt_qty,
        unit_cost
    from {{ ref('stg_fifo_transactions') }}
    where transaction_type = 'RECEIPT'
),

receipt_layers as (
    select
        receipt_id,
        warehouse_id,
        variant_id,
        receipt_timestamp,
        receipt_date,
        receipt_qty,
        unit_cost,
        coalesce(
            sum(receipt_qty) over (
                partition by warehouse_id, variant_id
                order by receipt_timestamp, receipt_id
                rows between unbounded preceding and 1 preceding
            ),
            0
        ) as cumulative_qty_before,
        sum(receipt_qty) over (
            partition by warehouse_id, variant_id
            order by receipt_timestamp, receipt_id
            rows between unbounded preceding and current row
        ) as cumulative_qty_after,
        DATEDIFF('day', receipt_date, DATE '2025-12-31') as days_since_receipt
    from receipts
)

select
    receipt_id,
    warehouse_id,
    variant_id,
    receipt_timestamp,
    receipt_date,
    receipt_qty,
    unit_cost,
    cumulative_qty_before,
    cumulative_qty_after,
    days_since_receipt,
    case
        when days_since_receipt <= 30 then 'Current (0-30)'
        when days_since_receipt <= 90 then 'Aging (31-90)'
        when days_since_receipt <= 180 then 'Slow (91-180)'
        else 'Obsolete (180+)'
    end as age_bucket
from receipt_layers
order by warehouse_id, variant_id, receipt_timestamp, receipt_id
EOF

# =============================================================================
# Model 3: int_pick_consumption.sql (cross-compatible)
# =============================================================================
cat > models/marts/inventory/int_pick_consumption.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with picks as (
    select
        transaction_id as pick_id,
        warehouse_id,
        variant_id,
        transaction_timestamp as pick_timestamp,
        transaction_date as pick_date,
        quantity as pick_qty
    from {{ ref('stg_fifo_transactions') }}
    where transaction_type = 'PICK'
)

select
    pick_id,
    warehouse_id,
    variant_id,
    pick_timestamp,
    pick_date,
    pick_qty,
    coalesce(
        sum(pick_qty) over (
            partition by warehouse_id, variant_id
            order by pick_timestamp, pick_id
            rows between unbounded preceding and 1 preceding
        ),
        0
    ) as consumption_start,
    sum(pick_qty) over (
        partition by warehouse_id, variant_id
        order by pick_timestamp, pick_id
        rows between unbounded preceding and current row
    ) as consumption_end
from picks
order by warehouse_id, variant_id, pick_timestamp, pick_id
EOF

# =============================================================================
# Model 4: int_fifo_allocation.sql (cross-compatible, boolean -> integer)
# =============================================================================
cat > models/marts/inventory/int_fifo_allocation.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with receipt_layers as (
    select * from {{ ref('int_receipt_layers') }}
),

pick_consumption as (
    select * from {{ ref('int_pick_consumption') }}
),

-- Total available before each pick timestamp
available_before_pick as (
    select
        p.pick_id,
        p.warehouse_id,
        p.variant_id,
        p.pick_timestamp,
        coalesce(sum(r.receipt_qty), 0) as total_available
    from pick_consumption p
    left join receipt_layers r
        on p.warehouse_id = r.warehouse_id
        and p.variant_id = r.variant_id
        and r.receipt_timestamp < p.pick_timestamp
    group by p.pick_id, p.warehouse_id, p.variant_id, p.pick_timestamp
),

-- Allocate picks to receipts using range overlap
allocations as (
    select
        p.pick_id,
        p.pick_timestamp,
        p.pick_date,
        p.warehouse_id,
        p.variant_id,
        r.receipt_id,
        r.unit_cost as receipt_unit_cost,
        p.pick_qty as pick_total_qty,
        p.consumption_start,
        p.consumption_end,
        r.cumulative_qty_before,
        r.cumulative_qty_after,
        greatest(0,
            least(r.cumulative_qty_after, p.consumption_end) -
            greatest(r.cumulative_qty_before, p.consumption_start)
        ) as allocated_qty,
        a.total_available as total_available_before_pick
    from pick_consumption p
    left join receipt_layers r
        on p.warehouse_id = r.warehouse_id
        and p.variant_id = r.variant_id
        and r.receipt_timestamp < p.pick_timestamp
        and r.cumulative_qty_after > p.consumption_start
        and r.cumulative_qty_before < p.consumption_end
    left join available_before_pick a
        on p.pick_id = a.pick_id
)

select
    pick_id,
    pick_timestamp,
    pick_date,
    warehouse_id,
    variant_id,
    receipt_id,
    receipt_unit_cost,
    coalesce(allocated_qty, 0) as allocated_qty,
    coalesce(allocated_qty, 0) * coalesce(receipt_unit_cost, 0) as allocation_cost,
    pick_total_qty,
    coalesce(total_available_before_pick, 0) as total_available_before_pick,
    case when pick_total_qty <= coalesce(total_available_before_pick, 0) then 1 else 0 end as is_fully_fulfilled
from allocations
where allocated_qty > 0 or receipt_id is null
order by warehouse_id, variant_id, pick_timestamp, pick_id
EOF

# =============================================================================
# Model 5: fifo_cogs_monthly.sql (needs DB_TYPE branching for date formatting)
# =============================================================================
if [ "$DB_TYPE" = "snowflake" ]; then

cat > models/marts/inventory/fifo_cogs_monthly.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with allocations as (
    select * from {{ ref('int_fifo_allocation') }}
),

product_categories as (
    select
        pv.variant_id,
        coalesce(pc.category_name, 'Uncategorized') as category_name
    from {{ source('product', 'PRODUCT_VARIANTS') }} pv
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
),

pick_metrics as (
    select
        a.pick_id,
        TO_VARCHAR(a.pick_date, 'YYYY-MM') as year_month,
        a.warehouse_id,
        pc.category_name,
        a.pick_total_qty,
        sum(a.allocated_qty) as fulfilled_qty,
        sum(a.allocation_cost) as cogs,
        max(a.is_fully_fulfilled) as is_fully_fulfilled
    from allocations a
    left join product_categories pc on a.variant_id = pc.variant_id
    group by a.pick_id, a.pick_date, a.warehouse_id, pc.category_name, a.pick_total_qty
),

monthly_summary as (
    select
        year_month,
        category_name,
        warehouse_id,
        count(distinct pick_id) as total_picks,
        sum(pick_total_qty) as total_units_requested,
        sum(fulfilled_qty) as total_units_fulfilled,
        sum(cogs) as total_cogs,
        sum(case when is_fully_fulfilled = 1 then 1 else 0 end) as pick_count_fully_fulfilled,
        sum(case when is_fully_fulfilled = 0 then 1 else 0 end) as pick_count_partial
    from pick_metrics
    group by year_month, category_name, warehouse_id
)

select
    year_month,
    category_name,
    warehouse_id,
    total_picks,
    round(total_units_requested, 2) as total_units_requested,
    round(total_units_fulfilled, 2) as total_units_fulfilled,
    round(total_units_requested - total_units_fulfilled, 2) as total_units_unfulfilled,
    round(total_cogs, 2) as total_cogs,
    round(case when total_units_fulfilled > 0 then total_cogs / total_units_fulfilled else null end, 2) as avg_fifo_unit_cost,
    round(case when total_units_requested > 0 then total_units_fulfilled / total_units_requested else 0 end, 4) as fulfillment_rate,
    pick_count_fully_fulfilled,
    pick_count_partial
from monthly_summary
order by year_month, category_name, warehouse_id
EOF

else

cat > models/marts/inventory/fifo_cogs_monthly.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with allocations as (
    select * from {{ ref('int_fifo_allocation') }}
),

product_categories as (
    select
        pv.variant_id,
        coalesce(pc.category_name, 'Uncategorized') as category_name
    from {{ source('product', 'PRODUCT_VARIANTS') }} pv
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
),

pick_metrics as (
    select
        a.pick_id,
        strftime(a.pick_date, '%Y-%m') as year_month,
        a.warehouse_id,
        pc.category_name,
        a.pick_total_qty,
        sum(a.allocated_qty) as fulfilled_qty,
        sum(a.allocation_cost) as cogs,
        max(a.is_fully_fulfilled) as is_fully_fulfilled
    from allocations a
    left join product_categories pc on a.variant_id = pc.variant_id
    group by a.pick_id, a.pick_date, a.warehouse_id, pc.category_name, a.pick_total_qty
),

monthly_summary as (
    select
        year_month,
        category_name,
        warehouse_id,
        count(distinct pick_id) as total_picks,
        sum(pick_total_qty) as total_units_requested,
        sum(fulfilled_qty) as total_units_fulfilled,
        sum(cogs) as total_cogs,
        sum(case when is_fully_fulfilled = 1 then 1 else 0 end) as pick_count_fully_fulfilled,
        sum(case when is_fully_fulfilled = 0 then 1 else 0 end) as pick_count_partial
    from pick_metrics
    group by year_month, category_name, warehouse_id
)

select
    year_month,
    category_name,
    warehouse_id,
    total_picks,
    round(total_units_requested, 2) as total_units_requested,
    round(total_units_fulfilled, 2) as total_units_fulfilled,
    round(total_units_requested - total_units_fulfilled, 2) as total_units_unfulfilled,
    round(total_cogs, 2) as total_cogs,
    round(case when total_units_fulfilled > 0 then total_cogs / total_units_fulfilled else null end, 2) as avg_fifo_unit_cost,
    round(case when total_units_requested > 0 then total_units_fulfilled / total_units_requested else 0 end, 4) as fulfillment_rate,
    pick_count_fully_fulfilled,
    pick_count_partial
from monthly_summary
order by year_month, category_name, warehouse_id
EOF

fi

# =============================================================================
# Model 6: ending_inventory_valuation.sql (cross-compatible)
# =============================================================================
cat > models/marts/inventory/ending_inventory_valuation.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with receipt_layers as (
    select * from {{ ref('int_receipt_layers') }}
),

total_consumption as (
    select
        warehouse_id,
        variant_id,
        sum(allocated_qty) as total_consumed
    from {{ ref('int_fifo_allocation') }}
    group by warehouse_id, variant_id
),

layer_remaining as (
    select
        r.receipt_id,
        r.warehouse_id,
        r.variant_id,
        r.receipt_date,
        r.receipt_qty,
        r.unit_cost,
        r.cumulative_qty_before,
        r.cumulative_qty_after,
        r.days_since_receipt,
        r.age_bucket,
        greatest(0,
            r.receipt_qty - greatest(0, coalesce(c.total_consumed, 0) - r.cumulative_qty_before)
        ) as remaining_qty
    from receipt_layers r
    left join total_consumption c
        on r.warehouse_id = c.warehouse_id
        and r.variant_id = c.variant_id
),

product_info as (
    select
        pv.variant_id,
        pv.sku,
        coalesce(pc.category_name, 'Uncategorized') as category_name
    from {{ source('product', 'PRODUCT_VARIANTS') }} pv
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
),

remaining_with_value as (
    select
        lr.warehouse_id,
        lr.variant_id,
        pi.sku,
        pi.category_name,
        lr.receipt_date,
        lr.remaining_qty,
        lr.remaining_qty * lr.unit_cost as remaining_value,
        lr.unit_cost,
        lr.days_since_receipt,
        lr.age_bucket,
        lr.remaining_qty * lr.days_since_receipt as weighted_days
    from layer_remaining lr
    join product_info pi on lr.variant_id = pi.variant_id
    where lr.remaining_qty > 0
),

variant_summary as (
    select
        warehouse_id,
        variant_id,
        sku,
        category_name,
        sum(remaining_qty) as total_units_remaining,
        sum(remaining_value) as total_value,
        count(*) as layer_count,
        min(receipt_date) as oldest_layer_date,
        max(receipt_date) as newest_layer_date,
        sum(weighted_days) / nullif(sum(remaining_qty), 0) as avg_days_in_inventory,
        sum(case when age_bucket = 'Current (0-30)' then remaining_qty else 0 end) as current_units,
        sum(case when age_bucket = 'Aging (31-90)' then remaining_qty else 0 end) as aging_units,
        sum(case when age_bucket = 'Slow (91-180)' then remaining_qty else 0 end) as slow_units,
        sum(case when age_bucket = 'Obsolete (180+)' then remaining_qty else 0 end) as obsolete_units,
        sum(case when age_bucket = 'Obsolete (180+)' then remaining_value else 0 end) as obsolete_value
    from remaining_with_value
    group by warehouse_id, variant_id, sku, category_name
)

select
    warehouse_id,
    variant_id,
    category_name,
    sku,
    round(total_units_remaining, 2) as total_units_remaining,
    round(total_value, 2) as total_value,
    round(total_value / nullif(total_units_remaining, 0), 2) as weighted_avg_cost,
    layer_count,
    oldest_layer_date,
    newest_layer_date,
    round(avg_days_in_inventory, 2) as avg_days_in_inventory,
    round(current_units, 2) as current_units,
    round(aging_units, 2) as aging_units,
    round(slow_units, 2) as slow_units,
    round(obsolete_units, 2) as obsolete_units,
    round(obsolete_value, 2) as obsolete_value
from variant_summary
where total_units_remaining > 0
order by warehouse_id, category_name, sku
EOF

# =============================================================================
# Model 7: inventory_turnover_analysis.sql (needs DB_TYPE branching for CROSS JOIN LATERAL and boolean)
# =============================================================================
if [ "$DB_TYPE" = "snowflake" ]; then

cat > models/marts/inventory/inventory_turnover_analysis.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with receipt_totals as (
    select
        r.warehouse_id,
        coalesce(pc.category_name, 'Uncategorized') as category_name,
        sum(r.receipt_qty) as total_receipts_qty,
        sum(r.receipt_qty * r.unit_cost) as total_receipts_value
    from {{ ref('int_receipt_layers') }} r
    join {{ source('product', 'PRODUCT_VARIANTS') }} pv on r.variant_id = pv.variant_id
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
    group by r.warehouse_id, coalesce(pc.category_name, 'Uncategorized')
),

-- First aggregate at pick level to avoid double-counting pick_total_qty
pick_level as (
    select
        a.pick_id,
        a.warehouse_id,
        a.variant_id,
        max(a.pick_total_qty) as pick_total_qty,
        sum(a.allocation_cost) as allocation_cost
    from {{ ref('int_fifo_allocation') }} a
    group by a.pick_id, a.warehouse_id, a.variant_id
),

pick_totals as (
    select
        pl.warehouse_id,
        coalesce(pc.category_name, 'Uncategorized') as category_name,
        sum(pl.pick_total_qty) as total_picks_qty,
        sum(pl.allocation_cost) as total_cogs
    from pick_level pl
    join {{ source('product', 'PRODUCT_VARIANTS') }} pv on pl.variant_id = pv.variant_id
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
    group by pl.warehouse_id, coalesce(pc.category_name, 'Uncategorized')
),

ending_inventory as (
    select
        warehouse_id,
        category_name,
        sum(total_units_remaining) as ending_inventory_qty,
        sum(total_value) as ending_inventory_value
    from {{ ref('ending_inventory_valuation') }}
    group by warehouse_id, category_name
),

combined as (
    select
        coalesce(r.warehouse_id, p.warehouse_id, e.warehouse_id) as warehouse_id,
        coalesce(r.category_name, p.category_name, e.category_name) as category_name,
        coalesce(r.total_receipts_qty, 0) as total_receipts_qty,
        coalesce(r.total_receipts_value, 0) as total_receipts_value,
        coalesce(p.total_picks_qty, 0) as total_picks_qty,
        coalesce(p.total_cogs, 0) as total_cogs,
        coalesce(e.ending_inventory_qty, 0) as ending_inventory_qty,
        coalesce(e.ending_inventory_value, 0) as ending_inventory_value
    from receipt_totals r
    full outer join pick_totals p
        on r.warehouse_id = p.warehouse_id and r.category_name = p.category_name
    full outer join ending_inventory e
        on coalesce(r.warehouse_id, p.warehouse_id) = e.warehouse_id
        and coalesce(r.category_name, p.category_name) = e.category_name
),

with_metrics as (
    select
        warehouse_id,
        category_name,
        total_receipts_qty,
        total_picks_qty,
        total_cogs,
        ending_inventory_qty,
        ending_inventory_value,
        (total_receipts_value + ending_inventory_value) / 2.0 as avg_inventory_value
    from combined
)

select
    warehouse_id,
    category_name,
    round(total_receipts_qty, 2) as total_receipts_qty,
    round(total_picks_qty, 2) as total_picks_qty,
    round(total_cogs, 2) as total_cogs,
    round(ending_inventory_qty, 2) as ending_inventory_qty,
    round(ending_inventory_value, 2) as ending_inventory_value,
    round(avg_inventory_value, 2) as avg_inventory_value,
    round(case when avg_inventory_value > 0 then total_cogs / avg_inventory_value else null end, 4) as inventory_turnover_ratio,
    round(case when avg_inventory_value > 0 and total_cogs > 0 then 365.0 / (total_cogs / avg_inventory_value) else null end, 2) as days_inventory_outstanding,
    round(case when total_receipts_qty > 0 then total_picks_qty / total_receipts_qty else null end, 4) as fulfillment_efficiency,
    case
        when (avg_inventory_value > 0 and total_cogs > 0 and 365.0 / (total_cogs / avg_inventory_value) > 90)
            or (avg_inventory_value > 0 and total_cogs / avg_inventory_value < 2)
        then 1
        else 0
    end as slow_moving_flag
from with_metrics
order by warehouse_id, category_name
EOF

else

cat > models/marts/inventory/inventory_turnover_analysis.sql << 'EOF'
{{
    config(
        materialized='table',
        schema='inventory_analytics'
    )
}}

with receipt_totals as (
    select
        r.warehouse_id,
        coalesce(pc.category_name, 'Uncategorized') as category_name,
        sum(r.receipt_qty) as total_receipts_qty,
        sum(r.receipt_qty * r.unit_cost) as total_receipts_value
    from {{ ref('int_receipt_layers') }} r
    join {{ source('product', 'PRODUCT_VARIANTS') }} pv on r.variant_id = pv.variant_id
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
    group by r.warehouse_id, coalesce(pc.category_name, 'Uncategorized')
),

-- First aggregate at pick level to avoid double-counting pick_total_qty
pick_level as (
    select
        a.pick_id,
        a.warehouse_id,
        a.variant_id,
        max(a.pick_total_qty) as pick_total_qty,
        sum(a.allocation_cost) as allocation_cost
    from {{ ref('int_fifo_allocation') }} a
    group by a.pick_id, a.warehouse_id, a.variant_id
),

pick_totals as (
    select
        pl.warehouse_id,
        coalesce(pc.category_name, 'Uncategorized') as category_name,
        sum(pl.pick_total_qty) as total_picks_qty,
        sum(pl.allocation_cost) as total_cogs
    from pick_level pl
    join {{ source('product', 'PRODUCT_VARIANTS') }} pv on pl.variant_id = pv.variant_id
    join {{ source('product', 'PRODUCTS') }} p on pv.product_id = p.product_id
    left join {{ source('product', 'PRODUCT_CATEGORIES') }} pc on p.primary_category_id = pc.category_id
    group by pl.warehouse_id, coalesce(pc.category_name, 'Uncategorized')
),

ending_inventory as (
    select
        warehouse_id,
        category_name,
        sum(total_units_remaining) as ending_inventory_qty,
        sum(total_value) as ending_inventory_value
    from {{ ref('ending_inventory_valuation') }}
    group by warehouse_id, category_name
),

combined as (
    select
        coalesce(r.warehouse_id, p.warehouse_id, e.warehouse_id) as warehouse_id,
        coalesce(r.category_name, p.category_name, e.category_name) as category_name,
        coalesce(r.total_receipts_qty, 0) as total_receipts_qty,
        coalesce(r.total_receipts_value, 0) as total_receipts_value,
        coalesce(p.total_picks_qty, 0) as total_picks_qty,
        coalesce(p.total_cogs, 0) as total_cogs,
        coalesce(e.ending_inventory_qty, 0) as ending_inventory_qty,
        coalesce(e.ending_inventory_value, 0) as ending_inventory_value
    from receipt_totals r
    full outer join pick_totals p
        on r.warehouse_id = p.warehouse_id and r.category_name = p.category_name
    full outer join ending_inventory e
        on coalesce(r.warehouse_id, p.warehouse_id) = e.warehouse_id
        and coalesce(r.category_name, p.category_name) = e.category_name
),

with_metrics as (
    select
        warehouse_id,
        category_name,
        total_receipts_qty,
        total_picks_qty,
        total_cogs,
        ending_inventory_qty,
        ending_inventory_value,
        (total_receipts_value + ending_inventory_value) / 2.0 as avg_inventory_value
    from combined
)

select
    warehouse_id,
    category_name,
    round(total_receipts_qty, 2) as total_receipts_qty,
    round(total_picks_qty, 2) as total_picks_qty,
    round(total_cogs, 2) as total_cogs,
    round(ending_inventory_qty, 2) as ending_inventory_qty,
    round(ending_inventory_value, 2) as ending_inventory_value,
    round(avg_inventory_value, 2) as avg_inventory_value,
    round(case when avg_inventory_value > 0 then total_cogs / avg_inventory_value else null end, 4) as inventory_turnover_ratio,
    round(case when avg_inventory_value > 0 and total_cogs > 0 then 365.0 / (total_cogs / avg_inventory_value) else null end, 2) as days_inventory_outstanding,
    round(case when total_receipts_qty > 0 then total_picks_qty / total_receipts_qty else null end, 4) as fulfillment_efficiency,
    case
        when (avg_inventory_value > 0 and total_cogs > 0 and 365.0 / (total_cogs / avg_inventory_value) > 90)
            or (avg_inventory_value > 0 and total_cogs / avg_inventory_value < 2)
        then true
        else false
    end as slow_moving_flag
from with_metrics
order by warehouse_id, category_name
EOF

fi

# Run dbt
dbt run --select stg_fifo_transactions int_receipt_layers int_pick_consumption int_fifo_allocation fifo_cogs_monthly ending_inventory_valuation inventory_turnover_analysis

echo "FIFO inventory models created successfully"
