{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_TRANSFERS

with source as (
    select * from {{ source('inventory', 'INVENTORY_TRANSFERS') }}
),

renamed as (
    select
        trim(transfer_id) as transfer_id,
        trim(transfer_number) as transfer_number,
        trim(transfer_type) as transfer_type,
        trim(source_type) as source_type,
        trim(source_warehouse_id) as source_warehouse_id,
        trim(source_store_id) as source_store_id,
        trim(dest_type) as dest_type,
        trim(dest_warehouse_id) as dest_warehouse_id,
        trim(dest_store_id) as dest_store_id,
        trim(status) as status,
        trim(priority) as priority,
        total_lines,
        total_quantity,
        total_value,
        trim(created_by) as created_by,
        created_at,
        updated_at
    from source
)

select * from renamed
