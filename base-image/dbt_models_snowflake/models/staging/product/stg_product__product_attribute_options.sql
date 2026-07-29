{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_ATTRIBUTE_OPTIONS

with source as (
    select * from {{ source('product', 'PRODUCT_ATTRIBUTE_OPTIONS') }}
),

renamed as (
    select
        trim(option_id) as option_id,
        trim(attribute_id) as attribute_id,
        trim(option_code) as option_code,
        trim(option_value) as option_value,
        trim(option_label) as option_label,
        sort_order,
        trim(swatch_type) as swatch_type,
        trim(swatch_value) as swatch_value,
        is_default,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
