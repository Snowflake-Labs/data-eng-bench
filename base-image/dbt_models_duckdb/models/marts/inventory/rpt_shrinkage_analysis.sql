-- Inventory Shrinkage Analysis
-- Inventory shrinkage analysis

with inventory_adjustments as (
    select * from {{ ref('stg_inventory__inventory_adjustments') }}
),

inventory_adjustment_lines as (
    select * from {{ ref('stg_inventory__inventory_adjustment_lines') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    w.warehouse_name,
    date_trunc('month', ia.created_at) as adjustment_month,
    count(distinct ia.adjustment_id) as adjustment_count,
    sum(case when ial.quantity_adjustment < 0 then abs(ial.quantity_adjustment) else 0 end) as units_shrinkage,
    sum(case when ial.quantity_adjustment < 0 then abs(ial.quantity_adjustment) * pv.cost_price else 0 end) as shrinkage_value,
    sum(case when ial.quantity_adjustment > 0 then ial.quantity_adjustment else 0 end) as units_found,
    sum(case when ial.quantity_adjustment > 0 then ial.quantity_adjustment * pv.cost_price else 0 end) as found_value
from inventory_adjustments ia
join inventory_adjustment_lines ial on ia.adjustment_id = ial.adjustment_id
left join warehouses w on ia.warehouse_id = w.warehouse_id
left join product_variants pv on ial.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1, 2