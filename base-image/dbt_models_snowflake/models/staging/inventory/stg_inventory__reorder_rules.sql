{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.REORDER_RULES

with source as (
    select * from {{ source('inventory', 'REORDER_RULES') }}
),

renamed as (
    select
        trim(rule_id) as rule_id,
        trim(variant_id) as variant_id,
        trim(warehouse_id) as warehouse_id,
        min_quantity,
        max_quantity,
        reorder_point,
        reorder_quantity,
        lead_time_days,
        safety_stock,
        trim(replenishment_method) as replenishment_method,
        is_active,
        effective_from,
        created_at,
        updated_at
    from source
)

select * from renamed
