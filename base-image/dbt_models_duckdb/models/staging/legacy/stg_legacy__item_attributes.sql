{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'product', 'attributes'],
        unique_key=['attribute_id']
    )
}}

/*
    Staging model: stg_legacy__item_attributes
    Grain: Per attribute definition
    Unique Key: attribute_id
    Source: RAW_LEGACY.ITMATTR (Item Attributes)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__itmattr') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(attribute_id as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        attribute_id,

        -- Attribute Definition
        attribute_code,
        attribute_name,
        attribute_description,
        attribute_type,
        data_type,
        attribute_group,

        -- Behavior Flags
        {{ safe_cast('is_variant_attribute', 'boolean') }} as is_variant_attribute,
        {{ safe_cast('is_filterable', 'boolean') }} as is_filterable,
        {{ safe_cast('is_searchable', 'boolean') }} as is_searchable,
        {{ safe_cast('is_comparable', 'boolean') }} as is_comparable,
        {{ safe_cast('is_required', 'boolean') }} as is_required,
        {{ safe_cast('is_active', 'boolean') }} as is_active,

        -- Validation
        default_value,
        validation_regex,
        min_value,
        max_value,

        -- Display
        {{ safe_cast('display_order', 'integer') }} as display_order,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,
        {{ standardize_date('updated_at') }} as updated_at,

        -- Current timestamp
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
