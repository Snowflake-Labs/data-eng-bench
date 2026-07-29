{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_IMAGES

with source as (
    select * from {{ source('product', 'PRODUCT_IMAGES') }}
),

renamed as (
    select
        trim(image_id) as image_id,
        trim(product_id) as product_id,
        trim(variant_id) as variant_id,
        trim(image_url) as image_url,
        trim(thumbnail_url) as thumbnail_url,
        trim(alt_text) as alt_text,
        trim(image_type) as image_type,
        sort_order,
        width,
        height,
        file_size_kb,
        is_primary,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
