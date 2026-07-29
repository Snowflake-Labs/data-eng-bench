{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.REVENUE_RECOGNITION

with source as (
    select * from {{ source('finance', 'REVENUE_RECOGNITION') }}
),

renamed as (
    select
        trim(recognition_id) as recognition_id,
        trim(order_id) as order_id,
        recognition_date,
        amount,
        trim(status) as status,
        created_at
    from source
)

select * from renamed
