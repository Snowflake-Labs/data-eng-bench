{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'product', 'images'],
        unique_key=['image_id']
    )
}}

/*
    Staging model: stg_legacy__item_images
    Grain: Per product image
    Unique Key: image_id
    Source: RAW_LEGACY.ITMIMG (Item Images)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__itmimg') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(image_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        image_id,

        -- Relationships
        product_id,
        variant_id,
        substr(product_id, 1, 10) as brand_id,  -- Link to brand

        -- Image Attributes
        image_url,
        thumbnail_url,
        alt_text,
        image_type,
        {{ safe_cast('sort_order', 'integer') }} as sort_order,

        -- Dimensions
        {{ safe_cast('width', 'integer') }} as width,
        {{ safe_cast('height', 'integer') }} as height,
        {{ safe_cast('file_size_kb', 'integer') }} as file_size_kb,

        -- Flags
        {{ safe_cast('is_primary', 'boolean') }} as is_primary,
        {{ safe_cast('is_active', 'boolean') }} as is_active,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,
        {{ standardize_date('updated_at') }} as updated_at,

        -- Metadata
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
