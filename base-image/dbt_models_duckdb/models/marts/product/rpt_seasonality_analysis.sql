-- Product Seasonality Analysis
-- Product seasonality analysis

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
    p.product_id,
    p.product_name,
    date_part('month', o.ordered_at) as month_of_year,
    date_part('dow', o.ordered_at) as day_of_week,
    count(distinct ol.order_line_id) as order_lines,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total - ol.discount_amount) as revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1, 2, 3, 4