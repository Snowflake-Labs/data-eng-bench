{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_TAGS

with source as (
    select * from {{ source('product', 'PRODUCT_TAGS') }}
),

renamed as (
    select
        trim(tag_id) as tag_id,
        trim(product_id) as product_id,
        trim(tag_name) as tag_name,
        trim(tag_type) as tag_type,
        created_at
    from source
)

select * from renamed
