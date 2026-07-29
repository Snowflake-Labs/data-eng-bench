{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_CONTACTS

with source as (
    select * from {{ source('customer', 'CUSTOMER_CONTACTS') }}
),

renamed as (
    select
        trim(contact_id) as contact_id,
        trim(customer_id) as customer_id,
        trim(contact_type) as contact_type,
        trim(contact_subtype) as contact_subtype,
        trim(contact_value) as contact_value,
        is_primary,
        is_verified,
        verified_at,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
