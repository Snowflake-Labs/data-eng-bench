-- Finance Revenue by Customer Segment
-- Revenue by customer segment

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
),

customer_segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
)

select
    cs.segment_name,
    DATE_TRUNC('month', o.ordered_at) as order_month,
    count(distinct o.order_id) as order_count,
    count(distinct o.customer_id) as customer_count,
    sum(ol.line_total) as gross_revenue,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value
from orders o
left join order_lines ol on o.order_id = ol.order_id
left join customers c on o.customer_id = c.customer_id
left join customer_segment_members csm on c.customer_id = csm.customer_id
left join customer_segments cs on csm.segment_id = cs.segment_id
group by 1, 2
