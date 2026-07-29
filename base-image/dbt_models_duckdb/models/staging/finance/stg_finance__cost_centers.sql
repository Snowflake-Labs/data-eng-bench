{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.COST_CENTERS

with source as (
    select * from {{ source('finance', 'COST_CENTERS') }}
),

renamed as (
    select
        trim(cost_center_id) as cost_center_id,
        trim(cost_center_code) as cost_center_code,
        trim(cost_center_name) as cost_center_name,
        trim(manager_id) as manager_id,
        is_active,
        created_at
    from source
)

select * from renamed
