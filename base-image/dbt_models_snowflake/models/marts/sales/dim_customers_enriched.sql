with customers as (
    select * from {{ ref('stg_customer__customers') }}
),
addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),
segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
),
segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
)

select
    c.customer_id,
    c.first_name,
    c.last_name,
    c.email,
    c.created_at,
    a.city,
    a.state_province,
    a.country_code,
    s.segment_name
from customers c
left join addresses a on c.customer_id = a.customer_id and a.is_default_billing = true
left join segment_members sm on c.customer_id = sm.customer_id and sm.is_active = true
left join segments s on sm.segment_id = s.segment_id
