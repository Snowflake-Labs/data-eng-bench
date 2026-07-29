-- Customer Consent History
-- Tracks consent changes over time

with customer_consent_log as (
    select * from {{ ref('stg_customer__customer_consent_log') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    DATE_TRUNC('month', ccl.created_at) as consent_month,
    ccl.consent_type,
    count(distinct ccl.customer_id) as customer_count,
    count(*) as total_actions
from customer_consent_log ccl
left join customers c on ccl.customer_id = c.customer_id
group by 1, 2
order by 1, 2
