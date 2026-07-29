{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.PROFIT_CENTERS

with source as (
    select * from {{ source('finance', 'PROFIT_CENTERS') }}
),

renamed as (
    select
        trim(profit_center_id) as profit_center_id,
        trim(profit_center_code) as profit_center_code,
        trim(profit_center_name) as profit_center_name,
        is_active,
        created_at
    from source
)

select * from renamed
