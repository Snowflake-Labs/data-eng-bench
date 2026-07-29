{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_ADJUSTMENT_LINES

with source as (
    select * from {{ source('inventory', 'INVENTORY_ADJUSTMENT_LINES') }}
),

renamed as (
    select
        trim(adjustment_line_id) as adjustment_line_id,
        trim(adjustment_id) as adjustment_id,
        line_number,
        trim(variant_id) as variant_id,
        trim(sku) as sku,
        quantity_before,
        quantity_adjustment,
        quantity_after,
        unit_cost,
        adjustment_value,
        created_at
    from source
)

select * from renamed
