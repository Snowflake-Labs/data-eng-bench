{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_ADDRESSES

with source as (
    select * from {{ source('customer', 'CUSTOMER_ADDRESSES') }}
),

renamed as (
    select
        trim(address_id) as address_id,
        trim(customer_id) as customer_id,
        trim(address_type) as address_type,
        trim(address_label) as address_label,
        is_default_billing,
        is_default_shipping,
        trim(recipient_name) as recipient_name,
        trim(company_name) as company_name,
        trim(address_line_1) as address_line_1,
        trim(address_line_2) as address_line_2,
        trim(address_line_3) as address_line_3,
        trim(city) as city,
        trim(state_province) as state_province,
        trim(postal_code) as postal_code,
        trim(country_code) as country_code,
        trim(phone) as phone,
        trim(delivery_instructions) as delivery_instructions,
        latitude,
        longitude,
        is_verified,
        verified_at,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
