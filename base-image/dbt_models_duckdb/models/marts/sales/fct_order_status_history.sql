-- Order Status History
-- Tracks order status changes

with order_status_history as (
    select * from {{ ref('stg_orders__order_status_history') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    osh.order_id,
    o.order_number,
    o.customer_id,
    osh.old_status,
    osh.new_status,
    osh.change_reason,
    osh.changed_at as status_changed_at,
    lag(osh.changed_at) over (partition by osh.order_id order by osh.changed_at) as previous_change_at,
    date_diff('hour', lag(osh.changed_at) over (partition by osh.order_id order by osh.changed_at), osh.changed_at) as hours_in_previous_status
from order_status_history osh
left join orders o on osh.order_id = o.order_id