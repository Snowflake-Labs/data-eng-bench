{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.SHOPPING_CARTS

with source as (
    select * from {{ source('digital', 'SHOPPING_CARTS') }}
),

renamed as (
    select
        trim(cart_id) as cart_id,
        trim(session_id) as session_id,
        trim(customer_id) as customer_id,
        trim(channel_id) as channel_id,
        trim(status) as status,
        item_count,
        subtotal,
        created_at,
        updated_at,
        converted_at,
        trim(order_id) as order_id
    from source
)

select * from renamed
