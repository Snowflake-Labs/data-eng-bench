-- Order Size Distribution
-- Analyzes order sizes

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
    case 
        when ol.total_items = 1 then '1 item'
        when ol.total_items between 2 and 3 then '2-3 items'
        when ol.total_items between 4 and 5 then '4-5 items'
        when ol.total_items between 6 and 10 then '6-10 items'
        else '10+ items'
    end as order_size_bucket,
    count(distinct o.order_id) as order_count,
    sum(o.grand_total) as total_revenue,
    avg(o.grand_total) as avg_order_value
from orders o
left join order_lines ol on o.order_id = ol.order_id
group by 1
