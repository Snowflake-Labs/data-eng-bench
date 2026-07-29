-- Year Over Year Comparison
-- Year over year comparison

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    DATE_TRUNC('month', o.ordered_at) as order_month,
    date_part('year', o.ordered_at) as order_year,
    date_part('month', o.ordered_at) as month_number,
    count(distinct o.order_id) as orders,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    count(distinct o.customer_id) as customers,
    avg(ol.line_total - ol.discount_amount) as avg_order_value,
    lag(sum(ol.line_total - ol.discount_amount), 12) over (order by DATE_TRUNC('month', o.ordered_at)) as prior_year_revenue,
    (sum(ol.line_total - ol.discount_amount) -
        lag(sum(ol.line_total - ol.discount_amount), 12) over (order by DATE_TRUNC('month', o.ordered_at))) /
        nullif(lag(sum(ol.line_total - ol.discount_amount), 12) over (order by DATE_TRUNC('month', o.ordered_at)), 0) as yoy_growth
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1, 2, 3
