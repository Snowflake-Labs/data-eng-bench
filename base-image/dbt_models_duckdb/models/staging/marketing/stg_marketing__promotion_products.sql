{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.PROMOTION_PRODUCTS

with source as (
    select * from {{ source('marketing', 'PROMOTION_PRODUCTS') }}
),

renamed as (
    select
        trim(mapping_id) as mapping_id,
        trim(promotion_id) as promotion_id,
        trim(product_id) as product_id,
        trim(category_id) as category_id,
        trim(brand_id) as brand_id,
        created_at
    from source
)

select * from renamed
