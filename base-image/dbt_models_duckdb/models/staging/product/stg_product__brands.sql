{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.BRANDS

with source as (
    select * from {{ source('product', 'BRANDS') }}
),

renamed as (
    select
        trim(brand_id) as brand_id,
        trim(brand_code) as brand_code,
        trim(brand_name) as brand_name,
        trim(brand_description) as brand_description,
        trim(brand_logo_url) as brand_logo_url,
        trim(brand_website) as brand_website,
        trim(parent_brand_id) as parent_brand_id,
        is_private_label,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
