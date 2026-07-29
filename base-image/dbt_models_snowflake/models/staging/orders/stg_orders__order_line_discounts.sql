{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_LINE_DISCOUNTS

with source as (
    select * from {{ source('orders', 'ORDER_LINE_DISCOUNTS') }}
),

renamed as (
    select
        trim(discount_id) as discount_id,
        trim(order_line_id) as order_line_id,
        trim(discount_type) as discount_type,
        trim(discount_code) as discount_code,
        trim(discount_name) as discount_name,
        discount_amount,
        created_at
    from source
)

select * from renamed
