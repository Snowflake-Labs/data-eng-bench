{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_TRANSFER_LINES

with source as (
    select * from {{ source('inventory', 'INVENTORY_TRANSFER_LINES') }}
),

renamed as (
    select
        trim(transfer_line_id) as transfer_line_id,
        trim(transfer_id) as transfer_id,
        line_number,
        trim(variant_id) as variant_id,
        trim(sku) as sku,
        quantity_requested,
        quantity_shipped,
        quantity_received,
        quantity_variance,
        unit_cost,
        line_value,
        created_at
    from source
)

select * from renamed
