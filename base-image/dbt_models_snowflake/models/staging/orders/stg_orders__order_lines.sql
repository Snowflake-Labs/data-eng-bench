{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_LINES

with source as (
    select * from {{ source('orders', 'ORDER_LINES') }}
),

renamed as (
    select
        trim(order_line_id) as order_line_id,
        trim(order_id) as order_id,
        line_number,
        trim(variant_id) as variant_id,
        trim(product_id) as product_id,
        trim(sku) as sku,
        trim(product_name) as product_name,
        trim(variant_name) as variant_name,
        quantity_ordered,
        quantity_shipped,
        quantity_returned,
        unit_price,
        discount_amount,
        tax_amount,
        line_total,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
