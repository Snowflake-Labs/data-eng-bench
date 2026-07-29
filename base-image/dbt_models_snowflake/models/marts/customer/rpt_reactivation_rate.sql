-- Customer Reactivation Rate
-- Customer reactivation analysis

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC('month', o.ordered_at) as order_month,
    count(distinct o.customer_id) as total_customers,
    count(distinct case
        when DATEDIFF(day,
            (select max(o2.ordered_at) from {{ ref('stg_orders__orders') }} o2
             where o2.customer_id = o.customer_id and o2.ordered_at < o.ordered_at),
            o.ordered_at) > 180
        then o.customer_id
    end) as reactivated_customers,
    count(distinct case
        when DATEDIFF(day,
            (select max(o2.ordered_at) from {{ ref('stg_orders__orders') }} o2
             where o2.customer_id = o.customer_id and o2.ordered_at < o.ordered_at),
            o.ordered_at) > 180
        then o.customer_id
    end) * 1.0 / nullif(count(distinct o.customer_id), 0) as reactivation_rate
from orders o
left join customers c on o.customer_id = c.customer_id
group by 1
