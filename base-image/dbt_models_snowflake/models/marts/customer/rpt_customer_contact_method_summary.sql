-- Customer Contact Method Summary
-- Summary of contact methods by type

with customer_contacts as (
    select * from {{ ref('stg_customer__customer_contacts') }}
)

select
    contact_type,
    count(distinct customer_id) as customers_count,
    count(distinct contact_id) as total_contacts,
    sum(case when is_primary then 1 else 0 end) as primary_count,
    sum(case when is_verified then 1 else 0 end) as verified_count,
    round(100.0 * sum(case when is_verified then 1 else 0 end) / nullif(count(distinct contact_id), 0), 2) as verification_rate
from customer_contacts
group by 1
