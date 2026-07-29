{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_ATTRIBUTES

with source as (
    select * from {{ source('product', 'PRODUCT_ATTRIBUTES') }}
),

renamed as (
    select
        trim(attribute_id) as attribute_id,
        trim(attribute_code) as attribute_code,
        trim(attribute_name) as attribute_name,
        trim(attribute_description) as attribute_description,
        trim(attribute_type) as attribute_type,
        trim(data_type) as data_type,
        is_variant_attribute,
        is_filterable,
        is_searchable,
        is_comparable,
        is_required,
        trim(default_value) as default_value,
        trim(validation_regex) as validation_regex,
        min_value,
        max_value,
        display_order,
        trim(attribute_group) as attribute_group,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
