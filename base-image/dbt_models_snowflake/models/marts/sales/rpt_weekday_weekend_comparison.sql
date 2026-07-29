-- Reference Weekday vs Weekend Sales
-- Weekday vs weekend comparison

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    DATE_TRUNC(week, o.ordered_at) as week_start,
    case
        when date_part('dow', o.ordered_at) in (0, 6) then 'WEEKEND'
        else 'WEEKDAY'
    end as day_type,
    count(distinct o.order_id) as orders,
    count(distinct o.customer_id) as customers,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value,
    sum(ol.quantity_ordered) as units_sold
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1, 2
