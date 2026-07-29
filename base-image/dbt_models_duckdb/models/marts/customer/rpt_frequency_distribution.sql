-- Customer Purchase Frequency Distribution
-- Purchase frequency distribution

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    order_count_bucket,
    count(distinct customer_id) as customer_count,
    count(distinct customer_id) * 100.0 / 
        nullif(sum(count(distinct customer_id)) over (), 0) as pct_of_customers
from (
    select 
        c.customer_id,
        case 
            when count(distinct o.order_id) = 0 then '0 orders'
            when count(distinct o.order_id) = 1 then '1 order'
            when count(distinct o.order_id) between 2 and 3 then '2-3 orders'
            when count(distinct o.order_id) between 4 and 6 then '4-6 orders'
            when count(distinct o.order_id) between 7 and 10 then '7-10 orders'
            else '11+ orders'
        end as order_count_bucket
    from customers c
    left join orders o on c.customer_id = o.customer_id
    group by 1
) customer_orders
group by 1
