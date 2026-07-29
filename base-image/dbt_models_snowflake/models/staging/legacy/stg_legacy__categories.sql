{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'reference', 'categories'],
        unique_key=['category_id']
    )
}}

/*
    Staging model: stg_legacy__categories
    Grain: Per category
    Unique Key: category_id
    Source: RAW_LEGACY.CATCOD (Category Codes)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__catcod') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(category_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        category_id,

        -- Category Attributes
        category_code,
        category_name,
        category_description,
        parent_category_id,
        category_level,
        category_path,
        category_path_ids,
        {{ safe_cast('sort_order', 'integer') }} as sort_order,

        -- Display Attributes
        image_url,
        icon_name,
        meta_title,
        meta_description,
        meta_keywords,

        -- Flags
        {{ safe_cast('is_featured', 'boolean') }} as is_featured,
        {{ safe_cast('is_active', 'boolean') }} as is_active,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,
        {{ standardize_date('updated_at') }} as updated_at,

        -- Metadata
        _loaded_at,
        _source_system,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
