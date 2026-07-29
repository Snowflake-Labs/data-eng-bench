-- Customer Monetary Distribution
-- Monetary value distribution

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    spend_bucket,
    count(distinct customer_id) as customer_count,
    count(distinct customer_id) * 100.0 / 
        nullif(sum(count(distinct customer_id)) over (), 0) as pct_of_customers
from (
    select 
        c.customer_id,
        case 
            when coalesce(sum(ol.line_total - ol.discount_amount), 0) = 0 then '$0'
            when sum(ol.line_total - ol.discount_amount) < 100 then '$1-99'
            when sum(ol.line_total - ol.discount_amount) < 500 then '$100-499'
            when sum(ol.line_total - ol.discount_amount) < 1000 then '$500-999'
            when sum(ol.line_total - ol.discount_amount) < 5000 then '$1,000-4,999'
            else '$5,000+'
        end as spend_bucket
    from customers c
    left join orders o on c.customer_id = o.customer_id
    left join order_lines ol on o.order_id = ol.order_id
    group by 1
) customer_spend
group by 1
