-- Customer Lifecycle Funnel
-- Tracks customer progression through lifecycle stages

with customer_lifecycle_events as (
    select * from {{ ref('stg_customer__customer_lifecycle_events') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    cle.event_type,
    DATE_TRUNC('month', cle.event_timestamp) as event_month,
    count(distinct cle.customer_id) as customers_count,
    count(*) as total_events
from customer_lifecycle_events cle
left join customers c on cle.customer_id = c.customer_id
group by 1, 2
order by 2, 1
