-- Sales Velocity Analysis
-- Sales velocity by product

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    p.product_id,
    p.product_name,
    min(o.ordered_at) as first_sale_date,
    max(o.ordered_at) as last_sale_date,
    date_diff('day', min(o.ordered_at), max(o.ordered_at)) as selling_days,
    sum(ol.quantity_ordered) as total_units_sold,
    sum(ol.quantity_ordered) * 1.0 / nullif(date_diff('day', min(o.ordered_at), max(o.ordered_at)), 0) as daily_velocity,
    sum(ol.quantity_ordered) * 7.0 / nullif(date_diff('day', min(o.ordered_at), max(o.ordered_at)), 0) as weekly_velocity,
    sum(ol.quantity_ordered) * 30.0 / nullif(date_diff('day', min(o.ordered_at), max(o.ordered_at)), 0) as monthly_velocity,
    case 
        when sum(ol.quantity_ordered) * 1.0 / nullif(date_diff('day', min(o.ordered_at), max(o.ordered_at)), 0) > 10 then 'Fast Mover'
        when sum(ol.quantity_ordered) * 1.0 / nullif(date_diff('day', min(o.ordered_at), max(o.ordered_at)), 0) > 1 then 'Medium Mover'
        else 'Slow Mover'
    end as velocity_tier
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1, 2