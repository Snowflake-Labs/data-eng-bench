{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_PRICES

with source as (
    select * from {{ source('product', 'PRODUCT_PRICES') }}
),

renamed as (
    select
        trim(price_id) as price_id,
        trim(variant_id) as variant_id,
        trim(price_type) as price_type,
        trim(currency_code) as currency_code,
        price_amount,
        compare_at_price,
        cost_price,
        min_qty,
        max_qty,
        trim(customer_tier_id) as customer_tier_id,
        trim(channel_id) as channel_id,
        effective_from,
        effective_to,
        is_active,
        created_at,
        updated_at,
        trim(created_by) as created_by
    from source
)

select * from renamed
