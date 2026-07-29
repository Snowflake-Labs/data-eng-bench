-- Customer Lifecycle Event Sequence
-- Tracks the sequence of events per customer

with customer_lifecycle_events as (
    select * from {{ ref('stg_customer__customer_lifecycle_events') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    cle.customer_id,
    c.customer_number,
    cle.event_type,
    cle.event_timestamp,
    row_number() over (partition by cle.customer_id order by cle.event_timestamp) as event_sequence,
    lag(cle.event_type) over (partition by cle.customer_id order by cle.event_timestamp) as previous_event,
    lag(cle.event_timestamp) over (partition by cle.customer_id order by cle.event_timestamp) as previous_event_time,
    DATEDIFF(hour, lag(cle.event_timestamp) over (partition by cle.customer_id order by cle.event_timestamp), cle.event_timestamp) as hours_since_previous
from customer_lifecycle_events cle
left join customers c on cle.customer_id = c.customer_id
