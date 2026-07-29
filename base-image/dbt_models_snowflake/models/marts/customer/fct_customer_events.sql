-- Fact Customer Events
-- Detailed fact table of all customer events

with customer_lifecycle_events as (
    select * from {{ ref('stg_customer__customer_lifecycle_events') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

dim_date as (
    select * from {{ ref('stg_analytics__dim_date') }}
)

select
    cle.event_id,
    cle.customer_id,
    c.customer_number,
    c.customer_type,
    cle.event_type,
    cle.event_timestamp,
    dd.full_date as event_date,
    dd.day_of_week,
    dd.quarter,
    dd.year,
    dd.is_holiday
from customer_lifecycle_events cle
left join customers c on cle.customer_id = c.customer_id
left join dim_date dd on DATE_TRUNC(day, cle.event_timestamp)::date = dd.full_date
