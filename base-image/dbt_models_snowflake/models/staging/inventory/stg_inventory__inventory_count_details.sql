{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_COUNT_DETAILS

with source as (
    select * from {{ source('inventory', 'INVENTORY_COUNT_DETAILS') }}
),

renamed as (
    select
        trim(count_detail_id) as count_detail_id,
        trim(count_id) as count_id,
        trim(variant_id) as variant_id,
        trim(sku) as sku,
        system_quantity,
        counted_quantity,
        variance_quantity,
        unit_cost,
        variance_value,
        trim(count_status) as count_status,
        trim(counted_by) as counted_by,
        counted_at,
        created_at,
        updated_at
    from source
)

select * from renamed
