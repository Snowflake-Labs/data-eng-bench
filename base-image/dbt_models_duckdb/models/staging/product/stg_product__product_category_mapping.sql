{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_CATEGORY_MAPPING

with source as (
    select * from {{ source('product', 'PRODUCT_CATEGORY_MAPPING') }}
),

renamed as (
    select
        trim(mapping_id) as mapping_id,
        trim(product_id) as product_id,
        trim(category_id) as category_id,
        is_primary,
        sort_order,
        created_at
    from source
)

select * from renamed
