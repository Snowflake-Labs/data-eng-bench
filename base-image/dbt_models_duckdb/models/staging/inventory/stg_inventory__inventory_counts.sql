{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.INVENTORY_COUNTS

with source as (
    select * from {{ source('inventory', 'INVENTORY_COUNTS') }}
),

renamed as (
    select
        trim(count_id) as count_id,
        trim(count_number) as count_number,
        trim(warehouse_id) as warehouse_id,
        trim(count_type) as count_type,
        trim(status) as status,
        scheduled_date,
        total_locations,
        total_skus,
        total_units_counted,
        total_variance_units,
        total_variance_value,
        trim(created_by) as created_by,
        created_at,
        updated_at
    from source
)

select * from renamed
