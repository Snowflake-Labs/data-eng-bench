-- Cross Domain Sales Inventory Summary
-- Combines sales and inventory data

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    p.product_id,
    p.product_name,
    w.warehouse_name,
    sum(ol.quantity_ordered) as units_sold,
    sum(il.quantity_on_hand) as current_inventory,
    sum(il.quantity_available) as available_inventory,
    sum(ol.line_total) as total_sales_revenue,
    sum(il.quantity_on_hand) * 1.0 / nullif(sum(ol.quantity_ordered), 0) as inventory_to_sales_ratio
from products p
left join product_variants pv on p.product_id = pv.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join inventory_levels il on pv.variant_id = il.variant_id
left join warehouses w on il.warehouse_id = w.warehouse_id
group by 1, 2, 3
