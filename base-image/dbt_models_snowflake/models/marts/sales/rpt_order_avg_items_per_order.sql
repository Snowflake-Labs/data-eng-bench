-- Order Average Items Per Order
-- Tracks average order size over time

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select
        order_id,
        count(*) as line_count,
        sum(quantity_ordered) as total_items
    from {{ ref('stg_orders__order_lines') }}
    group by 1
)

select
    DATE_TRUNC('month', o.ordered_at) as order_month,
    count(distinct o.order_id) as order_count,
    avg(ol.line_count) as avg_lines_per_order,
    avg(ol.total_items) as avg_items_per_order,
    sum(ol.total_items) as total_items_sold
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1
order by 1
