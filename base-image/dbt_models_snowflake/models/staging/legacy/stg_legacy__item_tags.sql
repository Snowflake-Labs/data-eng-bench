{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'product', 'tags'],
        unique_key=['tag_id']
    )
}}

/*
    Staging model: stg_legacy__item_tags
    Grain: Per tag (per product tag assignment)
    Unique Key: tag_id
    Source: RAW_LEGACY.ITMTAGS
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__itmtags') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(tag_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        tag_id,

        -- Relationships
        product_id,
        substr(product_id, 1, 10) as brand_id,  -- Link to brand
        substr(product_id, 11, 10) as category_id,  -- Link to category

        -- Tag Attributes
        tag_name,
        tag_type,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,

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
