{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.CONSENT_PREFERENCES

with source as (
    select * from {{ source('audit', 'CONSENT_PREFERENCES') }}
),

renamed as (
    select
        trim(preference_id) as preference_id,
        trim(customer_id) as customer_id,
        trim(consent_type) as consent_type,
        is_consented,
        consent_date,
        trim(ip_address) as ip_address,
        created_at
    from source
)

select * from renamed
