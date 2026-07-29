-- Inventory Safety Stock Analysis
-- Inventory safety stock analysis

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
)

select
    pv.variant_id,
    pv.sku,
    avg(ol.quantity_ordered) as avg_daily_demand,
    stddev(ol.quantity_ordered) as demand_stddev, il.quantity_on_hand as current_stock,
    -- Safety stock calculation (Z-score of 1.65 for 95% service level)
    1.65 * stddev(ol.quantity_ordered) * sqrt(7) as calculated_safety_stock,
    il.quantity_on_hand - (avg(ol.quantity_ordered) * 7) as current_safety_stock
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join inventory_levels il on pv.variant_id = il.variant_id
group by 1, 2, 5
