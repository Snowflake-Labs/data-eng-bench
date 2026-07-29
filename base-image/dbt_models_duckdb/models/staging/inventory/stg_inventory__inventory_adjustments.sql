{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_ADJUSTMENTS

with source as (
    select * from {{ source('inventory', 'INVENTORY_ADJUSTMENTS') }}
),

renamed as (
    select
        trim(adjustment_id) as adjustment_id,
        trim(adjustment_number) as adjustment_number,
        trim(warehouse_id) as warehouse_id,
        trim(adjustment_type) as adjustment_type,
        trim(status) as status,
        total_lines,
        total_quantity,
        total_value,
        trim(reason_code) as reason_code,
        trim(notes) as notes,
        trim(requested_by) as requested_by,
        requested_at,
        trim(approved_by) as approved_by,
        created_at,
        updated_at
    from source
)

select * from renamed
