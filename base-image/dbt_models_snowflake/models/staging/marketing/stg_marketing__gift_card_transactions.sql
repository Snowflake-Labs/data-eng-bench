{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.GIFT_CARD_TRANSACTIONS

with source as (
    select * from {{ source('marketing', 'GIFT_CARD_TRANSACTIONS') }}
),

renamed as (
    select
        trim(transaction_id) as transaction_id,
        trim(gift_card_id) as gift_card_id,
        trim(transaction_type) as transaction_type,
        amount,
        balance_after,
        trim(order_id) as order_id,
        created_at
    from source
)

select * from renamed
