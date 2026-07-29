{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIER_ADDRESSES

with source as (
    select * from {{ source('procurement', 'SUPPLIER_ADDRESSES') }}
),

renamed as (
    select
        trim(address_id) as address_id,
        trim(supplier_id) as supplier_id,
        trim(address_type) as address_type,
        trim(address_line_1) as address_line_1,
        trim(city) as city,
        trim(state_province) as state_province,
        trim(postal_code) as postal_code,
        trim(country_code) as country_code,
        is_primary,
        created_at
    from source
)

select * from renamed
