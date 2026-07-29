-- Product Lifecycle Stage
-- Product lifecycle analysis

with products as (
    select * from {{ ref('stg_product__products') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    p.product_name,
    date_diff('day', coalesce(min(o.ordered_at), current_date), current_date) as days_in_market,
    min(o.ordered_at) as first_sale_date,
    max(o.ordered_at) as last_sale_date,
    sum(ol.quantity_ordered) as lifetime_units_sold,
    sum(ol.line_total - ol.discount_amount) as lifetime_revenue,
    case
        when max(p.discontinued_at) is not null then 'DISCONTINUED'
        when date_diff('day', min(o.ordered_at), current_date) <= 90 then 'INTRODUCTION'
        when sum(ol.quantity_ordered) is null then 'NO SALES'
        else 'ACTIVE'
    end as lifecycle_stage
from products p
left join product_variants pv on p.product_id = pv.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
group by 1