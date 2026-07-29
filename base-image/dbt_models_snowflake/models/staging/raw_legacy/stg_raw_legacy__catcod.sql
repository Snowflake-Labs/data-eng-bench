with source as (
    select * from {{ source('raw_legacy', 'catcod') }}
),

renamed as (
    select
        category_id as category_id,
        category_code as category_code,
        category_name as category_name,
        category_description as category_description,
        parent_category_id as parent_category_id,
        category_level as category_level,
        category_path as category_path,
        category_path_ids as category_path_ids, sort_order as sort_order,
        image_url as image_url,
        icon_name as icon_name,
        meta_title as meta_title,
        meta_description as meta_description,
        meta_keywords as meta_keywords,
        is_featured as is_featured,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id, _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
