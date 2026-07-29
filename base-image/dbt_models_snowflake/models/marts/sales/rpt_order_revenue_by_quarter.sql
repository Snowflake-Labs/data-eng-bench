-- Order Revenue by Quarter
-- Quarterly revenue analysis

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

dim_date as (
    select * from {{ ref('stg_analytics__dim_date') }}
)

select
    dd.year,
    dd.quarter,
    count(distinct o.order_id) as order_count,
    count(distinct o.customer_id) as unique_customers,
    sum(o.grand_total) as total_revenue,
    sum(o.discount_total) as total_discounts,
    avg(o.grand_total) as avg_order_value
from orders o
left join dim_date dd on DATE_TRUNC(day, o.ordered_at)::date = dd.full_date
group by 1, 2
order by 1, 2
