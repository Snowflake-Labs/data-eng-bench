{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.LOYALTY_POINTS_TRANSACTIONS

with source as (
    select * from {{ source('marketing', 'LOYALTY_POINTS_TRANSACTIONS') }}
),

renamed as (
    select
        trim(transaction_id) as transaction_id,
        trim(customer_id) as customer_id,
        trim(program_id) as program_id,
        trim(transaction_type) as transaction_type,
        points,
        balance_after,
        trim(order_id) as order_id,
        trim(description) as description,
        expires_at,
        created_at
    from source
)

select * from renamed
