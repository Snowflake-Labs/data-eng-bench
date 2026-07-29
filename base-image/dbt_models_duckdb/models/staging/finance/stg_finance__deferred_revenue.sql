{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.DEFERRED_REVENUE

with source as (
    select * from {{ source('finance', 'DEFERRED_REVENUE') }}
),

renamed as (
    select
        trim(deferred_id) as deferred_id,
        trim(order_id) as order_id,
        amount,
        recognition_start,
        recognition_end,
        recognized_amount,
        remaining_amount,
        created_at
    from source
)

select * from renamed
