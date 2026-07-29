-- Customer Lifecycle Duration
-- Calculates time between lifecycle events

with customer_lifecycle_events as (
    select * from {{ ref('stg_customer__customer_lifecycle_events') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    cle.customer_id,
    c.customer_number,
    c.customer_type,
    min(cle.event_timestamp) as first_event,
    max(cle.event_timestamp) as last_event,
    date_diff('day', cast(min(cle.event_timestamp) as date), cast(max(cle.event_timestamp) as date)) as lifecycle_days,
    count(distinct cle.event_type) as unique_event_types,
    count(*) as total_events
from customer_lifecycle_events cle
left join customers c on cle.customer_id = c.customer_id
group by 1, 2, 3
