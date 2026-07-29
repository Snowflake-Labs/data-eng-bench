{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.DIM_PRODUCT

with source as (
    select * from {{ source('analytics', 'DIM_PRODUCT') }}
),

renamed as (
    select
        product_key,
        trim(product_id) as product_id,
        trim(sku) as sku,
        trim(product_name) as product_name,
        trim(brand_name) as brand_name,
        trim(category_name) as category_name,
        trim(subcategory_name) as subcategory_name,
        unit_price,
        unit_cost,
        is_active,
        effective_from,
        effective_to,
        is_current
    from source
)

select * from renamed
