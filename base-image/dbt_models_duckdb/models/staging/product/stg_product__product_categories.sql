{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_CATEGORIES

with source as (
    select * from {{ source('product', 'PRODUCT_CATEGORIES') }}
),

renamed as (
    select
        trim(category_id) as category_id,
        trim(category_code) as category_code,
        trim(category_name) as category_name,
        trim(category_description) as category_description,
        trim(parent_category_id) as parent_category_id,
        category_level,
        trim(category_path) as category_path,
        trim(category_path_ids) as category_path_ids,
        sort_order,
        trim(image_url) as image_url,
        trim(icon_name) as icon_name,
        trim(meta_title) as meta_title,
        trim(meta_description) as meta_description,
        trim(meta_keywords) as meta_keywords,
        is_featured,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
