{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.WAREHOUSE_LOCATIONS

with source as (
    select * from {{ source('inventory', 'WAREHOUSE_LOCATIONS') }}
),

renamed as (
    select
        trim(location_id) as location_id,
        trim(warehouse_id) as warehouse_id,
        trim(zone_id) as zone_id,
        trim(location_code) as location_code,
        trim(location_barcode) as location_barcode,
        trim(aisle) as aisle,
        trim(rack) as rack,
        trim(shelf) as shelf,
        trim(location_type) as location_type,
        is_pickable,
        is_receivable,
        max_weight,
        pick_sequence,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
