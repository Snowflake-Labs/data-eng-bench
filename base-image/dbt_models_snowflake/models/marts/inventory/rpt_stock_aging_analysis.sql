with src_stg_inventory__inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),
src_stg_product__products as (
    select * from {{ ref('stg_product__products') }}
),

-- Calculates how long inventory has been sitting
inventory_levels as (
    select * from src_stg_inventory__inventory_levels
),
products as (
    select * from src_stg_product__products
)

select
    l.variant_id,
    p.product_name,
    l.warehouse_id,
    l.quantity_on_hand,
    l.last_received_at,
    DATEDIFF(day, l.last_received_at::date, current_date) as days_in_stock,
    case
        when DATEDIFF(day, l.last_received_at::date, current_date) > 365 then 'Over 1 Year'
        when DATEDIFF(day, l.last_received_at::date, current_date) > 180 then '6-12 Months'
        else 'Fresh'
    end as age_category
from inventory_levels l
left join products p on l.variant_id = p.product_id
where l.quantity_on_hand > 0
