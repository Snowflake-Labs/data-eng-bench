with src_stg_product__products as (
    select * from {{ ref('stg_product__products') }}
),
sales as (
    select 
        product_id, 
        sum(quantity_ordered) as units_sold,
        sum(quantity_ordered * unit_price) as revenue
    from {{ ref('stg_orders__order_lines') }}
    group by 1
),
costs as (
    select variant_id, unit_cost from {{ ref('stg_inventory__inventory_levels') }}
)

select 
    s.product_id,
    p.product_name,
    s.revenue,
    (s.units_sold * coalesce(c.unit_cost, 0)) as total_cogs,
    (s.revenue - (s.units_sold * coalesce(c.unit_cost, 0))) as gross_profit,
    case when s.revenue > 0 
         then (s.revenue - (s.units_sold * coalesce(c.unit_cost, 0))) / s.revenue 
         else 0 
    end as margin_pct
from sales s
left join costs c on s.product_id = c.variant_id
join src_stg_product__products p on s.product_id = p.product_id