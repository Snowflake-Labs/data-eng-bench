-- Customer Contact History
-- Customer contact history summary

with customer_contacts as (
    select * from {{ ref('stg_customer__customer_contacts') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    c.customer_id,
    c.email,
    DATE_TRUNC('month', cc.created_at) as contact_month,
    cc.contact_type,
    count(distinct cc.contact_id) as contact_count,
    count(case when cc.is_verified = true then 1 end) as verified_contacts
from customer_contacts cc
left join customers c on cc.customer_id = c.customer_id
group by 1, 2, 3, 4
