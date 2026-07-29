{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.WAREHOUSE_ZONES

with source as (
    select * from {{ source('inventory', 'WAREHOUSE_ZONES') }}
),

renamed as (
    select
        trim(zone_id) as zone_id,
        trim(warehouse_id) as warehouse_id,
        trim(zone_code) as zone_code,
        trim(zone_name) as zone_name,
        trim(zone_type) as zone_type,
        temperature_controlled,
        min_temperature,
        max_temperature,
        capacity_units,
        sort_order,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
