-- Order Notes Summary
-- Summarizes notes on orders

with order_notes as (
    select * from {{ ref('stg_orders__order_notes') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    onn.note_type,
    onn.is_internal,
    count(distinct onn.order_id) as orders_with_notes,
    count(distinct onn.note_id) as total_notes,
    avg(length(onn.note_text)) as avg_note_length
from order_notes onn
left join orders o on onn.order_id = o.order_id
group by 1, 2
