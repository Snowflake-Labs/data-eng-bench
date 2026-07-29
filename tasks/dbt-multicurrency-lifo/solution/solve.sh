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

# Create symlink so /app/dbt_transforms points to the active project
ln -sfn "$DBT_PROJECT_DIR" /app/dbt_transforms

# Generate profiles.yml based on DB_TYPE
if [ "$DB_TYPE" = "snowflake" ]; then
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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
else
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
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create directory structure for new models
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts"

# Overwrite generate_schema_name macro so all models land in the default schema
mkdir -p "$DBT_PROJECT_DIR/macros/utils"
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
MACRO

# ============ INTERMEDIATE MODELS ============

cat > "$DBT_PROJECT_DIR/models/intermediate/int_finance__exchange_rates_daily.sql" << 'EOF'
{{
    config(
        materialized='view',
        tags=['intermediate']
    )
}}
-- Intermediate model for daily exchange rates with proper date handling
select
    effective_date as rate_date,
    from_currency,
    to_currency,
    exchange_rate as rate_to_usd
from {{ ref('stg_finance__currency_exchange_rates') }}
where to_currency = 'USD'
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_procurement__purchases_enriched.sql" << 'EOF'
{{
    config(
        materialized='view',
        tags=['intermediate']
    )
}}
-- Intermediate model joining purchase order lines with headers
select
    l.po_line_id as purchase_id,
    l.po_id,
    l.sku,
    l.quantity_received as quantity,
    l.unit_price as unit_cost,
    h.currency_code as currency,
    CAST(h.ordered_at AS DATE) as purchase_date
from {{ ref('stg_procurement__purchase_order_lines') }} l
inner join {{ ref('stg_procurement__purchase_orders') }} h
    on l.po_id = h.po_id
where l.sku is not null
  and l.quantity_received is not null
  and l.quantity_received > 0
  and l.unit_price is not null
  and l.unit_price > 0
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_orders__sales_enriched.sql" << 'EOF'
{{
    config(
        materialized='view',
        tags=['intermediate']
    )
}}
-- Intermediate model joining order lines with order headers
select
    l.order_line_id as sale_id,
    l.order_id,
    l.sku,
    l.quantity_ordered as quantity_sold,
    CAST(h.ordered_at AS DATE) as sale_date
from {{ ref('stg_orders__order_lines') }} l
inner join {{ ref('stg_orders__orders') }} h
    on l.order_id = h.order_id
where l.sku is not null
  and l.quantity_ordered is not null
  and l.quantity_ordered > 0
EOF

# ============ MART MODELS ============

# Mart: purchase_costs_usd.sql
cat > "$DBT_PROJECT_DIR/models/marts/purchase_costs_usd.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}
/*
Convert all purchase costs to USD using exchange rates.
Uses most recent exchange rate on or before purchase date.
USD purchases have exchange_rate = 1.0.
Excludes non-USD purchases without available exchange rates.
*/

with purchases as (
    select * from {{ ref('int_procurement__purchases_enriched') }}
),

rates as (
    select * from {{ ref('int_finance__exchange_rates_daily') }}
),

-- Find the most recent rate for each purchase
purchase_with_rate as (
    select
        p.purchase_id,
        p.sku,
        p.quantity,
        p.currency,
        p.unit_cost,
        p.purchase_date,
        r.rate_to_usd as exchange_rate,
        row_number() over (
            partition by p.purchase_id
            order by r.rate_date desc
        ) as rate_rank
    from purchases p
    left join rates r
        on p.currency = r.from_currency
        and r.rate_date <= p.purchase_date
    where p.currency = 'USD' or r.rate_to_usd is not null
),

-- Filter to best rate and handle USD
final as (
    select
        purchase_id,
        sku,
        CAST(quantity AS INTEGER) as quantity,
        currency as original_currency,
        unit_cost as original_unit_cost,
        purchase_date,
        case
            when currency = 'USD' then 1.000000
            else round(exchange_rate, 6)
        end as exchange_rate,
        round(
            CAST(unit_cost AS DOUBLE) *
            case when currency = 'USD' then 1.0 else exchange_rate end,
            4
        ) as unit_cost_usd,
        round(
            CAST(unit_cost AS DOUBLE) *
            case when currency = 'USD' then 1.0 else exchange_rate end *
            quantity,
            2
        ) as total_cost_usd
    from purchase_with_rate
    where rate_rank = 1 or currency = 'USD'
)

select * from final
order by purchase_date, purchase_id
EOF

# Mart: sale_cogs.sql - LIFO inventory costing with weighted average fallback
cat > "$DBT_PROJECT_DIR/models/marts/sale_cogs.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}
/*
LIFO (Last-In, First-Out) Inventory Costing with Multi-Currency Support
and Weighted-Average Fallback Costing

Implements periodic LIFO:
- All purchases are pooled as available inventory
- Sales consume from most recent purchases first (by date, then by ID DESC)
- Tracks inventory shortfall when demand exceeds supply
- Calculates fallback cost using weighted average for shortfall quantities
- Classifies costing method as LIFO_FULL, LIFO_PARTIAL, or LIFO_NONE
*/

with purchase_costs as (
    -- Get purchases ordered for LIFO (newest first)
    select
        purchase_id,
        sku,
        CAST(quantity AS INTEGER) as quantity,
        unit_cost_usd,
        total_cost_usd,
        purchase_date,
        -- Running cumulative quantity for LIFO matching (newest first)
        coalesce(sum(quantity) over (
            partition by sku
            order by purchase_date desc, purchase_id desc
            rows between unbounded preceding and 1 preceding
        ), 0) as cum_qty_start,
        sum(quantity) over (
            partition by sku
            order by purchase_date desc, purchase_id desc
        ) as cum_qty_end
    from {{ ref('purchase_costs_usd') }}
),

-- Calculate weighted average cost per SKU for fallback costing
sku_weighted_avg as (
    select
        sku,
        sum(total_cost_usd) / nullif(sum(quantity), 0) as weighted_avg_cost
    from {{ ref('purchase_costs_usd') }}
    group by sku
),

sales as (
    -- Get sales ordered chronologically (for consumption order)
    select
        sale_id,
        order_id,
        sku,
        CAST(quantity_sold AS INTEGER) as quantity_sold,
        sale_date,
        -- Running cumulative sales for matching against inventory
        coalesce(sum(quantity_sold) over (
            partition by sku
            order by sale_date, sale_id
            rows between unbounded preceding and 1 preceding
        ), 0) as cum_sold_start,
        sum(quantity_sold) over (
            partition by sku
            order by sale_date, sale_id
        ) as cum_sold_end
    from {{ ref('int_orders__sales_enriched') }}
),

-- Get total inventory per SKU
sku_inventory as (
    select sku, coalesce(sum(quantity), 0) as total_inventory
    from purchase_costs
    group by sku
),

-- Match sales to purchase batches using cumulative quantity ranges
matched as (
    select
        s.sale_id,
        s.order_id,
        s.sku,
        s.sale_date,
        s.quantity_sold,
        p.purchase_id,
        p.unit_cost_usd,
        -- Calculate how much of this batch is consumed by this sale
        case
            when p.purchase_id is not null then
                greatest(0,
                    least(s.cum_sold_end, p.cum_qty_end) -
                    greatest(s.cum_sold_start, p.cum_qty_start)
                )
            else 0
        end as qty_from_batch
    from sales s
    left join purchase_costs p
        on s.sku = p.sku
        and p.cum_qty_start < s.cum_sold_end
        and p.cum_qty_end > s.cum_sold_start
),

-- Aggregate COGS per sale
sale_cogs_calc as (
    select
        sale_id,
        order_id,
        sku,
        sale_date,
        quantity_sold,
        coalesce(sum(case when qty_from_batch > 0 then qty_from_batch * unit_cost_usd else 0 end), 0) as cogs_usd,
        coalesce(count(distinct case when qty_from_batch > 0 then purchase_id end), 0) as batches_consumed,
        coalesce(sum(case when qty_from_batch > 0 then qty_from_batch else 0 end), 0) as qty_fulfilled
    from matched
    group by sale_id, order_id, sku, sale_date, quantity_sold
),

-- Calculate final values with shortfall and fallback costing
final as (
    select
        c.sale_id,
        c.order_id,
        c.sku,
        c.sale_date,
        c.quantity_sold,
        round(c.cogs_usd, 2) as cogs_usd,
        case
            when c.qty_fulfilled > 0 then round(CAST(c.cogs_usd AS DOUBLE) / CAST(c.qty_fulfilled AS DOUBLE), 4)
            else 0.0000
        end as avg_unit_cost,
        CAST(c.batches_consumed AS INTEGER) as batches_consumed,
        CAST(c.quantity_sold - c.qty_fulfilled AS INTEGER) as inventory_shortfall,
        -- Fallback cost for shortfall using weighted average
        round(
            case
                when c.quantity_sold - c.qty_fulfilled > 0
                then (c.quantity_sold - c.qty_fulfilled) * coalesce(w.weighted_avg_cost, 0)
                else 0
            end,
            2
        ) as fallback_cost_usd,
        -- Total estimated COGS including fallback
        round(
            c.cogs_usd +
            case
                when c.quantity_sold - c.qty_fulfilled > 0
                then (c.quantity_sold - c.qty_fulfilled) * coalesce(w.weighted_avg_cost, 0)
                else 0
            end,
            2
        ) as total_estimated_cogs,
        -- Costing method classification
        case
            when c.quantity_sold - c.qty_fulfilled = 0 then 'LIFO_FULL'
            when c.batches_consumed > 0 then 'LIFO_PARTIAL'
            else 'LIFO_NONE'
        end as costing_method
    from sale_cogs_calc c
    left join sku_weighted_avg w on c.sku = w.sku
)

select * from final
order by sale_date, sale_id
EOF

# Mart: inventory_turnover_metrics.sql - SKU-level inventory analytics
cat > "$DBT_PROJECT_DIR/models/marts/inventory_turnover_metrics.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}
/*
Inventory Turnover Metrics

Calculates SKU-level inventory analytics including:
- Total purchased and sold quantities/costs
- Remaining inventory using LIFO layers (oldest costs remain)
- Weighted average costs for purchases and sales
- Inventory turnover ratio
*/

with purchase_totals as (
    select
        sku,
        CAST(sum(quantity) AS INTEGER) as total_purchased_qty,
        round(sum(total_cost_usd), 2) as total_purchased_cost_usd
    from {{ ref('purchase_costs_usd') }}
    group by sku
),

sale_totals as (
    select
        sku,
        CAST(sum(quantity_sold) AS INTEGER) as total_sold_qty,
        round(sum(cogs_usd), 2) as total_cogs_usd,
        CAST(sum(inventory_shortfall) AS INTEGER) as total_shortfall
    from {{ ref('sale_cogs') }}
    group by sku
),

-- Calculate remaining inventory (purchases - fulfilled sales)
remaining_inventory as (
    select
        coalesce(p.sku, s.sku) as sku,
        coalesce(p.total_purchased_qty, 0) -
            (coalesce(s.total_sold_qty, 0) - coalesce(s.total_shortfall, 0)) as remaining_qty
    from purchase_totals p
    full outer join sale_totals s on p.sku = s.sku
),

-- Get purchase batches for remaining inventory valuation (FIFO - oldest first)
purchase_batches as (
    select
        sku,
        quantity,
        unit_cost_usd,
        purchase_date,
        purchase_id,
        row_number() over (partition by sku order by purchase_date, purchase_id) as batch_order,
        sum(quantity) over (
            partition by sku
            order by purchase_date, purchase_id
        ) as cum_qty
    from {{ ref('purchase_costs_usd') }}
),

-- Calculate remaining inventory cost using FIFO (oldest batches remain after LIFO consumption)
remaining_cost_calc as (
    select
        r.sku,
        r.remaining_qty,
        coalesce(
            sum(
                case
                    when r.remaining_qty <= 0 then 0
                    when pb.cum_qty <= r.remaining_qty then pb.quantity * pb.unit_cost_usd
                    when pb.cum_qty - pb.quantity < r.remaining_qty then
                        (r.remaining_qty - (pb.cum_qty - pb.quantity)) * pb.unit_cost_usd
                    else 0
                end
            ),
            0
        ) as remaining_cost
    from remaining_inventory r
    left join purchase_batches pb on r.sku = pb.sku
    group by r.sku, r.remaining_qty
),

-- Calculate fulfilled quantity for weighted average sale cost
fulfilled_totals as (
    select
        sku,
        sum(quantity_sold - inventory_shortfall) as total_fulfilled_qty
    from {{ ref('sale_cogs') }}
    group by sku
),

final as (
    select
        coalesce(p.sku, s.sku) as sku,
        coalesce(p.total_purchased_qty, 0) as total_purchased_qty,
        coalesce(p.total_purchased_cost_usd, 0.00) as total_purchased_cost_usd,
        coalesce(s.total_sold_qty, 0) as total_sold_qty,
        coalesce(s.total_cogs_usd, 0.00) as total_cogs_usd,
        CAST(coalesce(ri.remaining_qty, 0) AS INTEGER) as remaining_inventory_qty,
        round(
            case
                when coalesce(ri.remaining_qty, 0) > 0 then coalesce(rc.remaining_cost, 0)
                else 0
            end,
            2
        ) as remaining_inventory_cost_usd,
        round(
            case
                when coalesce(p.total_purchased_qty, 0) > 0
                then CAST(p.total_purchased_cost_usd AS DOUBLE) / CAST(p.total_purchased_qty AS DOUBLE)
                else 0
            end,
            4
        ) as weighted_avg_purchase_cost,
        round(
            case
                when coalesce(f.total_fulfilled_qty, 0) > 0
                then CAST(s.total_cogs_usd AS DOUBLE) / CAST(f.total_fulfilled_qty AS DOUBLE)
                else 0
            end,
            4
        ) as weighted_avg_sale_cost,
        -- Inventory turnover ratio: COGS / Average Inventory
        -- Assuming beginning inventory = 0, average = ending / 2
        round(
            case
                when coalesce(ri.remaining_qty, 0) > 0 and rc.remaining_cost > 0
                then CAST(s.total_cogs_usd AS DOUBLE) / (CAST(rc.remaining_cost AS DOUBLE) / 2)
                else null
            end,
            4
        ) as inventory_turnover_ratio,
        -- Gross margin percentage - NULL as no standard sale price available
        CAST(null AS DOUBLE) as gross_margin_pct
    from purchase_totals p
    full outer join sale_totals s on p.sku = s.sku
    left join remaining_inventory ri on coalesce(p.sku, s.sku) = ri.sku
    left join remaining_cost_calc rc on coalesce(p.sku, s.sku) = rc.sku
    left join fulfilled_totals f on coalesce(p.sku, s.sku) = f.sku
)

select * from final
order by sku
EOF

# Run dbt
cd "$DBT_PROJECT_DIR"
dbt deps
dbt run --select \
  stg_finance__currency_exchange_rates \
  stg_procurement__purchase_orders \
  stg_procurement__purchase_order_lines \
  stg_orders__orders \
  stg_orders__order_lines \
  int_finance__exchange_rates_daily \
  int_procurement__purchases_enriched \
  int_orders__sales_enriched \
  purchase_costs_usd \
  sale_cogs \
  inventory_turnover_metrics

echo "Solution complete!"
