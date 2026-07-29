-- Customer Lifecycle Events Summary
-- Aggregates lifecycle events by customer and event type

with customer_lifecycle_events as (
    select * from {{ ref('stg_customer__customer_lifecycle_events') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    cle.customer_id,
    c.customer_number,
    c.first_name,
    c.last_name,
    cle.event_type,
    count(*) as event_count,
    min(cle.event_timestamp) as first_event_at,
    max(cle.event_timestamp) as last_event_at,
    DATEDIFF(day, cast(min(cle.event_timestamp) as date), cast(max(cle.event_timestamp) as date)) as days_between_first_last
from customer_lifecycle_events cle
left join customers c on cle.customer_id = c.customer_id
group by 1, 2, 3, 4, 5
