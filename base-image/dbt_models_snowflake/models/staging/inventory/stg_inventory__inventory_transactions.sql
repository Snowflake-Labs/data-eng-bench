{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_TRANSACTIONS

with source as (
    select * from {{ source('inventory', 'INVENTORY_TRANSACTIONS') }}
),

renamed as (
    select
        trim(transaction_id) as transaction_id,
        trim(variant_id) as variant_id,
        trim(warehouse_id) as warehouse_id,
        trim(transaction_type) as transaction_type,
        quantity,
        trim(uom) as uom,
        quantity_before,
        quantity_after,
        unit_cost,
        trim(reference_type) as reference_type,
        trim(reference_number) as reference_number,
        transaction_date,
        transaction_timestamp,
        trim(created_by) as created_by,
        created_at
    from source
)

select * from renamed
