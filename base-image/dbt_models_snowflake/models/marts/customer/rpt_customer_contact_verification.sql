-- Customer Contact Verification Status
-- Shows verification status of customer contacts

with customer_contacts as (
    select * from {{ ref('stg_customer__customer_contacts') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    c.customer_id,
    c.customer_number,
    c.email,
    count(distinct cc.contact_id) as total_contacts,
    sum(case when cc.is_verified then 1 else 0 end) as verified_contacts,
    sum(case when not cc.is_verified then 1 else 0 end) as unverified_contacts,
    round(100.0 * sum(case when cc.is_verified then 1 else 0 end) / nullif(count(distinct cc.contact_id), 0), 2) as verification_rate_pct
from customers c
left join customer_contacts cc on c.customer_id = cc.customer_id
group by 1, 2, 3
