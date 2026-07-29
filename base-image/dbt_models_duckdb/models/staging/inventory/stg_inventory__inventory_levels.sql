{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_LEVELS

with source as (
    select * from {{ source('inventory', 'INVENTORY_LEVELS') }}
),

renamed as (
    select
        trim(inventory_id) as inventory_id,
        trim(variant_id) as variant_id,
        trim(location_type) as location_type,
        trim(warehouse_id) as warehouse_id,
        trim(store_id) as store_id,
        trim(location_id) as location_id,
        quantity_on_hand,
        quantity_available,
        quantity_reserved,
        quantity_incoming,
        quantity_on_hold,
        unit_cost,
        trim(inventory_status) as inventory_status,
        last_counted_at,
        last_received_at,
        last_picked_at,
        created_at,
        updated_at
    from source
)

select * from renamed
