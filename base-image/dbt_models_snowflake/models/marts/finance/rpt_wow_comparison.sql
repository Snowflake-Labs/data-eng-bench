-- Week Over Week Comparison
-- Week over week comparison

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    DATE_TRUNC(week, o.ordered_at) as order_week,
    count(distinct o.order_id) as orders,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    count(distinct o.customer_id) as customers,
    avg(ol.line_total - ol.discount_amount) as avg_order_value,
    lag(sum(ol.line_total - ol.discount_amount)) over (order by DATE_TRUNC(week, o.ordered_at)) as prior_week_revenue,
    (sum(ol.line_total - ol.discount_amount) -
        lag(sum(ol.line_total - ol.discount_amount)) over (order by DATE_TRUNC(week, o.ordered_at))) /
        nullif(lag(sum(ol.line_total - ol.discount_amount)) over (order by DATE_TRUNC(week, o.ordered_at)), 0) as wow_growth
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1
