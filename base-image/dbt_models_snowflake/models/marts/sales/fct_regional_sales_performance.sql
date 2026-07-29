with orders as (
    select * from {{ ref('stg_orders__orders') }}
),
customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),
dim_geography as (
    select * from {{ ref('stg_analytics__dim_geography') }}
)

select
    g.country_name,
    g.state_name,
    DATE_TRUNC(quarter, o.ordered_at) as sales_quarter,
    sum(o.grand_total) as revenue,
    count(distinct o.order_id) as order_count
from orders o
join customer_addresses ca on o.customer_id = ca.customer_id and ca.is_default_billing = true
join dim_geography g on ca.country_code = g.country_code and ca.state_province = g.state_name
group by 1,2,3
