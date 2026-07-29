-- Product Recommendation Features
-- Product recommendation features

with order_lines as (
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
)

select
    o.customer_id,
    p.product_id,
    p.product_name,
    count(distinct ol.order_line_id) as times_purchased,
    sum(ol.quantity_ordered) as total_quantity,
    sum(ol.line_total - ol.discount_amount) as total_spent,
    min(o.ordered_at) as first_purchase_date,
    max(o.ordered_at) as last_purchase_date,
    date_diff('day', min(o.ordered_at), max(o.ordered_at)) / nullif(count(distinct ol.order_line_id) - 1, 0) as avg_repurchase_days
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1, 2, 3