{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIER_CONTACTS

with source as (
    select * from {{ source('procurement', 'SUPPLIER_CONTACTS') }}
),

renamed as (
    select
        trim(contact_id) as contact_id,
        trim(supplier_id) as supplier_id,
        trim(contact_name) as contact_name,
        trim(contact_type) as contact_type,
        trim(email) as email,
        trim(phone) as phone,
        is_primary,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
