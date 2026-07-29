-- Order Day of Week Analysis
-- Orders by day of week

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

dim_date as (
    select * from {{ ref('stg_analytics__dim_date') }}
)

select
    dd.day_of_week,
    count(distinct o.order_id) as order_count,
    sum(o.grand_total) as total_revenue,
    avg(o.grand_total) as avg_order_value,
    count(distinct o.customer_id) as unique_customers
from orders o
left join dim_date dd on date_trunc('day', o.ordered_at)::date = dd.full_date
group by 1
order by 1
