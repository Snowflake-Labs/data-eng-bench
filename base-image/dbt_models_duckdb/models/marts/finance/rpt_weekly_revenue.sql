-- Finance Weekly Revenue
-- Weekly revenue summary

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    date_trunc('week', o.ordered_at) as revenue_week,
    count(distinct o.order_id) as order_count,
    count(distinct o.customer_id) as customer_count,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.line_total) as gross_revenue,
    sum(ol.discount_amount) as total_discounts,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1