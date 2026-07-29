{{
    config(
        materialized='table',
        tags=['mart', 'inventory', 'metrics']
    )
}}

/*
================================================================================
MODEL: rpt_product_inventory_metrics
AUTHOR: Tyler Brooks
CREATED: 2024-02-15
LAST MODIFIED: 2024-11-20 by Marcus Johnson

DESCRIPTION:
Product-level inventory performance metrics including turnover ratios,
stockout analysis, and inventory health indicators.

KNOWN ISSUES:
  - Performance: Full refresh takes ~8 minutes on large datasets
  - TODO: Add warehouse-level breakdown

CHANGE LOG:
  2024-11-20: Added days_of_supply calculation (Marcus)
  2024-08-10: Fixed COGS join issue (Tyler)
  2024-02-15: Initial creation (Tyler)
================================================================================
*/

with inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

inventory_transactions as (
    select * from {{ ref('stg_inventory__inventory_transactions') }}
),

-- Aggregate inventory at product level
product_inventory as (
    select
        il.variant_id as product_id,
        sum(il.quantity_on_hand) as total_quantity_on_hand,
        sum(il.quantity_available) as total_quantity_available,
        sum(il.quantity_reserved) as total_quantity_reserved,
        sum(il.quantity_on_hand * il.unit_cost) as total_inventory_value,
        avg(il.unit_cost) as avg_unit_cost,
        count(distinct il.warehouse_id) as warehouse_count,
        count(case when il.inventory_status = 'OUT_OF_STOCK' then 1 end) as stockout_location_count,
        count(distinct il.inventory_id) as total_locations,
        max(il.last_received_at) as last_received_date,
        max(il.last_picked_at) as last_picked_date
    from inventory_levels il
    group by il.variant_id
),

-- Calculate COGS from outbound transactions (last 365 days)
product_cogs as (
    select
        variant_id as product_id,
        sum(quantity * unit_cost) as cogs_365d,
        sum(quantity) as units_sold_365d,
        count(distinct transaction_date) as selling_days
    from inventory_transactions
    where transaction_type = 'PICK'
      and transaction_date >= current_date - interval '365' day
    group by variant_id
),

-- Calculate average inventory value (simplified - using current snapshot)
avg_inventory as (
    select
        variant_id as product_id,
        avg(quantity_on_hand * unit_cost) as avg_inventory_value_365d
    from inventory_levels
    group by variant_id
),

-- Calculate daily demand for days of supply
daily_demand as (
    select
        variant_id as product_id,
        sum(quantity) / 365.0 as avg_daily_demand
    from inventory_transactions
    where transaction_type = 'PICK'
      and transaction_date >= current_date - interval '365' day
    group by variant_id
),

-- Combine all metrics
product_metrics as (
    select
        pi.product_id,
        cast(null as varchar) as product_name,
        cast(null as varchar) as product_code,
        cast(null as varchar) as category_id,
        cast(null as varchar) as lifecycle_status,
        cast(null as varchar) as abc_classification,

        -- Inventory quantities
        coalesce(pi.total_quantity_on_hand, 0) as total_quantity_on_hand,
        coalesce(pi.total_quantity_available, 0) as total_quantity_available,
        coalesce(pi.total_quantity_reserved, 0) as total_quantity_reserved,
        coalesce(pi.total_inventory_value, 0) as total_inventory_value,
        coalesce(pi.avg_unit_cost, 0) as avg_unit_cost,
        coalesce(pi.warehouse_count, 0) as warehouse_count,

        -- Sales metrics
        coalesce(pc.cogs_365d, 0) as cogs_365d,
        coalesce(pc.units_sold_365d, 0) as units_sold_365d,
        coalesce(pc.selling_days, 0) as selling_days,

        pc.cogs_365d / ai.avg_inventory_value_365d as turnover_ratio,

        pi.total_inventory_value / pc.units_sold_365d as inventory_value_per_unit_sold,

        -- Stockout metrics
        coalesce(pi.stockout_location_count, 0) as stockout_location_count,
        coalesce(pi.total_locations, 0) as total_locations,

        100.0 * pi.stockout_location_count / pi.total_locations as stockout_rate,

        pi.total_quantity_on_hand / dd.avg_daily_demand as days_of_supply,

        -- Activity dates
        pi.last_received_date,
        pi.last_picked_date,

        -- Days since activity
        date_diff('day', pi.last_picked_date, current_date) as days_since_last_pick,
        date_diff('day', pi.last_received_date, current_date) as days_since_last_receipt

    from product_inventory pi
    left join product_cogs pc on pi.product_id = pc.product_id
    left join avg_inventory ai on pi.product_id = ai.product_id
    left join daily_demand dd on pi.product_id = dd.product_id
    -- Only include products with active inventory
    where coalesce(pi.total_quantity_on_hand, 0) > 0
      and pi.product_id is not null
)

select
    product_id,
    product_name,
    product_code,
    category_id,
    lifecycle_status,
    abc_classification,
    total_quantity_on_hand,
    total_quantity_available,
    total_quantity_reserved,
    round(total_inventory_value, 2) as total_inventory_value,
    round(avg_unit_cost, 2) as avg_unit_cost,
    warehouse_count,
    round(cogs_365d, 2) as cogs_365d,
    units_sold_365d,
    selling_days,
    round(turnover_ratio, 4) as turnover_ratio,
    round(inventory_value_per_unit_sold, 2) as inventory_value_per_unit_sold,
    stockout_location_count,
    total_locations,
    round(stockout_rate, 2) as stockout_rate,
    round(days_of_supply, 1) as days_of_supply,
    last_received_date,
    last_picked_date,
    days_since_last_pick,
    days_since_last_receipt
from product_metrics
