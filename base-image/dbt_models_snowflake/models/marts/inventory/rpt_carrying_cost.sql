-- Inventory Carrying Cost
-- Inventory carrying cost analysis

with inventory_levels as (
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
    w.warehouse_name,
    sum(il.quantity_on_hand * pv.cost_price) as inventory_value,
    -- Assuming 20% annual carrying cost rate
    sum(il.quantity_on_hand * pv.cost_price) * 0.20 / 12 as monthly_carrying_cost,
    sum(il.quantity_on_hand) as total_units,
    avg(DATEDIFF(day, il.last_received_at, current_date)) as avg_days_in_inventory,
    -- Carrying cost per day
    sum(il.quantity_on_hand * pv.cost_price) * 0.20 / 365 as daily_carrying_cost
from inventory_levels il
left join product_variants pv on il.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
left join warehouses w on il.warehouse_id = w.warehouse_id
group by 1
