-- Inventory Stockout Risk
-- Identifies stockout risk

with inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
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
    w.warehouse_name,
    p.product_name,
    pv.sku,
    il.quantity_on_hand,
    il.quantity_available,
    avg(ol.quantity_ordered) as avg_daily_sales,
    il.quantity_available / nullif(avg(ol.quantity_ordered), 0) as days_until_stockout,
    case
        when il.quantity_available <= 10 then 'HIGH'
        when il.quantity_available <= 20 then 'MEDIUM'
        else 'LOW'
    end as stockout_risk
from inventory_levels il
left join product_variants pv on il.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
left join warehouses w on il.warehouse_id = w.warehouse_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id and o.ordered_at >= DATEADD(day, -30, current_date)
group by 1, 2, 3, 4, 5
