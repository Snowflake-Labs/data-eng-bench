{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.STORES

with source as (
    select * from {{ source('inventory', 'STORES') }}
),

renamed as (
    select
        trim(store_id) as store_id,
        trim(store_number) as store_number,
        trim(store_name) as store_name,
        trim(store_type) as store_type,
        trim(store_format) as store_format,
        trim(address_line_1) as address_line_1,
        trim(city) as city,
        trim(state_province) as state_province,
        trim(postal_code) as postal_code,
        trim(country_code) as country_code,
        latitude,
        longitude,
        trim(timezone) as timezone,
        trim(phone) as phone,
        trim(email) as email,
        square_footage,
        opened_date,
        supports_bopis,
        supports_ship_from_store,
        supports_returns,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
