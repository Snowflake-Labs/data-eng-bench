with source as (
    select * from {{ source('raw_legacy', 'itmimg_stg') }}
),

renamed as (
    select
        image_id as image_id,
        product_id as product_id,
        variant_id as variant_id,
        image_url as image_url,
        thumbnail_url as thumbnail_url,
        alt_text as alt_text,
        image_type as image_type,
        sort_order as sort_order,
        width as width,
        height as height,
        file_size_kb as file_size_kb,
        is_primary as is_primary,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _status as _status
    from source
)

select * from renamed
