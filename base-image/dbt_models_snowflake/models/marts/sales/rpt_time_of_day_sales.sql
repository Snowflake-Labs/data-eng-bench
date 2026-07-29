-- Reference Time of Day Sales
-- Time of day sales analysis

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    DATE_TRUNC(day, o.ordered_at) as order_date,
    case
        when date_part('hour', o.ordered_at) between 0 and 5 then 'EARLY MORNING'
        when date_part('hour', o.ordered_at) between 6 and 11 then 'MORNING'
        when date_part('hour', o.ordered_at) between 12 and 17 then 'AFTERNOON'
        when date_part('hour', o.ordered_at) between 18 and 21 then 'EVENING'
        else 'NIGHT'
    end as time_of_day,
    count(distinct o.order_id) as orders,
    sum(ol.line_total - ol.discount_amount) as net_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1, 2
