{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.WAREHOUSES

with source as (
    select * from {{ source('inventory', 'WAREHOUSES') }}
),

renamed as (
    select
        trim(warehouse_id) as warehouse_id,
        trim(warehouse_code) as warehouse_code,
        trim(warehouse_name) as warehouse_name,
        trim(warehouse_type) as warehouse_type,
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
        trim(manager_name) as manager_name,
        square_footage,
        max_capacity_units,
        opened_date,
        priority,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
