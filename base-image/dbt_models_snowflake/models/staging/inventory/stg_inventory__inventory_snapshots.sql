{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_SNAPSHOTS

with source as (
    select * from {{ source('inventory', 'INVENTORY_SNAPSHOTS') }}
),

renamed as (
    select
        trim(snapshot_id) as snapshot_id,
        snapshot_date,
        trim(variant_id) as variant_id,
        trim(warehouse_id) as warehouse_id,
        quantity_on_hand,
        quantity_available,
        quantity_reserved,
        quantity_incoming,
        unit_cost,
        total_value,
        created_at
    from source
)

select * from renamed
