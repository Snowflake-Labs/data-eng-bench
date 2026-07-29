-- Marketing Audience Segments
-- Audience segmentation

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

customer_preferences as (
    select * from {{ ref('stg_customer__customer_preferences') }}
)

select
    c.customer_id,
    c.email,
    count(distinct o.order_id) as order_count,
    sum(ol.line_total - ol.discount_amount) as total_spend,
    date_diff('day', max(o.ordered_at), current_date) as days_since_last_order,
    case 
        when count(distinct o.order_id) = 0 then 'NEVER PURCHASED'
        when count(distinct o.order_id) = 1 then 'ONE-TIME BUYER'
        when count(distinct o.order_id) between 2 and 5 then 'REPEAT BUYER'
        else 'LOYAL CUSTOMER'
    end as purchase_segment,
    case 
        when sum(ol.line_total - ol.discount_amount) >= 1000 then 'HIGH VALUE'
        when sum(ol.line_total - ol.discount_amount) >= 250 then 'MEDIUM VALUE'
        else 'LOW VALUE'
    end as value_segment
from customers c
left join orders o on c.customer_id = o.customer_id
left join order_lines ol on o.order_id = ol.order_id
left join customer_preferences cp on c.customer_id = cp.customer_id
group by 1, 2