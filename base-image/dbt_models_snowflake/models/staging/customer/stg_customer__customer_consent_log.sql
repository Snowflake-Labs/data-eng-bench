{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_CONSENT_LOG

with source as (
    select * from {{ source('customer', 'CUSTOMER_CONSENT_LOG') }}
),

renamed as (
    select
        trim(consent_id) as consent_id,
        trim(customer_id) as customer_id,
        trim(consent_type) as consent_type,
        trim(consent_version) as consent_version,
        is_consented,
        trim(consent_text) as consent_text,
        trim(ip_address) as ip_address,
        trim(user_agent) as user_agent,
        trim(consent_source) as consent_source,
        consent_timestamp,
        expiry_date,
        withdrawn_at,
        trim(withdrawal_reason) as withdrawal_reason,
        created_at
    from source
)

select * from renamed
