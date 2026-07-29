-- Customer Data Quality Score
-- Scores customer data completeness

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

customer_contacts as (
    select customer_id, count(*) as contact_count from {{ ref('stg_customer__customer_contacts') }} group by 1
),

customer_addresses as (
    select customer_id, count(*) as address_count from {{ ref('stg_customer__customer_addresses') }} group by 1
)

select
    c.customer_id,
    c.customer_number,
    c.email,
    case when c.first_name is not null and c.first_name != '' then 10 else 0 end +
    case when c.last_name is not null and c.last_name != '' then 10 else 0 end +
    case when c.email is not null and c.email != '' then 20 else 0 end +
    case when c.phone_primary is not null and c.phone_primary != '' then 15 else 0 end +
    case when cc.contact_count > 0 then 20 else 0 end +
    case when ca.address_count > 0 then 25 else 0 end as data_quality_score,
    cc.contact_count,
    ca.address_count
from customers c
left join customer_contacts cc on c.customer_id = cc.customer_id
left join customer_addresses ca on c.customer_id = ca.customer_id