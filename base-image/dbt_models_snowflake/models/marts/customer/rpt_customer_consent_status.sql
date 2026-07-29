-- Customer Consent Status
-- Current consent status for each customer and consent type

with customer_consent_log as (
    select * from {{ ref('stg_customer__customer_consent_log') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

latest_consent as (
    select
        customer_id,
        consent_type,
        is_consented,
        created_at,
        row_number() over (partition by customer_id, consent_type order by created_at desc) as rn
    from customer_consent_log
)

select
    lc.customer_id,
    c.customer_number,
    c.email,
    lc.consent_type, lc.is_consented as current_consent_status,
    lc.created_at as consent_updated_at
from latest_consent lc
left join customers c on lc.customer_id = c.customer_id
where lc.rn = 1
