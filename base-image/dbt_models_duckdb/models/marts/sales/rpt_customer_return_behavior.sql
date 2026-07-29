-- Customer Return Behavior
-- Analyzes which customers return most

with returns as (
    select * from {{ ref('stg_orders__returns') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    r.customer_id,
    count(distinct r.return_id) as return_count,
    count(distinct r.order_id) as orders_with_returns,
    sum(r.refund_amount) as total_refunded,
    avg(r.refund_amount) as avg_refund_amount,
    min(r.created_at) as first_return,
    max(r.created_at) as last_return
from returns r
left join orders o on r.order_id = o.order_id
group by 1
