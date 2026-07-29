{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_PAYMENTS

with source as (
    select * from {{ source('orders', 'ORDER_PAYMENTS') }}
),

renamed as (
    select
        trim(payment_id) as payment_id,
        trim(order_id) as order_id,
        trim(payment_method_id) as payment_method_id,
        trim(payment_method) as payment_method,
        amount,
        trim(currency_code) as currency_code,
        trim(status) as status,
        trim(transaction_id) as transaction_id,
        trim(authorization_code) as authorization_code,
        trim(card_last_four) as card_last_four,
        trim(card_type) as card_type,
        processed_at,
        created_at,
        updated_at
    from source
)

select * from renamed
