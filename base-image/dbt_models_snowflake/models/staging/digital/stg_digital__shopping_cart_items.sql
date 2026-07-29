{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.SHOPPING_CART_ITEMS

with source as (
    select * from {{ source('digital', 'SHOPPING_CART_ITEMS') }}
),

renamed as (
    select
        trim(cart_item_id) as cart_item_id,
        trim(cart_id) as cart_id,
        trim(variant_id) as variant_id,
        quantity,
        unit_price,
        line_total,
        added_at,
        updated_at
    from source
)

select * from renamed
