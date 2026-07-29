-- Executive Revenue Overview
-- Revenue overview dashboard

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    DATE_TRUNC('month', o.ordered_at) as period_month,
    count(distinct o.order_id) as total_orders,
    count(distinct o.customer_id) as unique_customers,
    sum(ol.line_total) as gross_revenue,
    sum(ol.discount_amount) as total_discounts,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value,
    sum(ol.quantity_ordered) as units_sold,
    lag(sum(ol.line_total - ol.discount_amount)) over (order by DATE_TRUNC('month', o.ordered_at)) as prev_month_revenue,
    (sum(ol.line_total - ol.discount_amount) - lag(sum(ol.line_total - ol.discount_amount)) over (order by DATE_TRUNC('month', o.ordered_at))) /
        nullif(lag(sum(ol.line_total - ol.discount_amount)) over (order by DATE_TRUNC('month', o.ordered_at)), 0) as mom_growth
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1
