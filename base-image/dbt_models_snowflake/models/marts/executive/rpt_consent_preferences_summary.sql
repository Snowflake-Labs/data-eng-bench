-- Consent Preferences Summary
-- Summarizes consent preferences

with consent_preferences as (
    select * from {{ ref('stg_audit__consent_preferences') }}
)

select
    consent_type, is_consented as is_granted,
    count(distinct preference_id) as preference_count,
    count(distinct customer_id) as unique_customers,
    min(consent_date) as first_granted,
    max(consent_date) as last_granted
from consent_preferences
group by 1, 2
