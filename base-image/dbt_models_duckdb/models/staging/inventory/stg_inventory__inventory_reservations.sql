{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_RESERVATIONS

with source as (
    select * from {{ source('inventory', 'INVENTORY_RESERVATIONS') }}
),

renamed as (
    select
        trim(reservation_id) as reservation_id,
        trim(variant_id) as variant_id,
        trim(warehouse_id) as warehouse_id,
        trim(reservation_type) as reservation_type,
        trim(reference_type) as reference_type,
        trim(reference_id) as reference_id,
        quantity_reserved,
        trim(status) as status,
        priority,
        reserved_at,
        expires_at,
        trim(created_by) as created_by
    from source
)

select * from renamed
