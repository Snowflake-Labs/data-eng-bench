-- Executive Channel Performance
-- Channel performance dashboard

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

channels as (
    select * from {{ ref('stg_orders__channels') }}
)

select
    c.channel_name,
    date_trunc('month', o.ordered_at) as order_month,
    count(distinct o.order_id) as orders,
    count(distinct o.customer_id) as customers,
    sum(ol.line_total) as gross_revenue,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value,
    sum(ol.quantity_ordered) as units_sold,
    sum(ol.discount_amount) / nullif(sum(ol.line_total), 0) as discount_rate,
    count(distinct o.order_id) * 1.0 / nullif(count(distinct o.customer_id), 0) as orders_per_customer
from orders o
left join order_lines ol on o.order_id = ol.order_id
left join channels c on o.channel_id = c.channel_id
group by 1, 2