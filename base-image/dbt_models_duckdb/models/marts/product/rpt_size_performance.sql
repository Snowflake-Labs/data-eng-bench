-- Product Size Performance
-- Product size performance

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
    date_trunc('month', o.ordered_at) as order_month,
    count(distinct ol.order_line_id) as order_lines,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.unit_price) as avg_selling_price
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
where pv.variant_name is not null
group by 1