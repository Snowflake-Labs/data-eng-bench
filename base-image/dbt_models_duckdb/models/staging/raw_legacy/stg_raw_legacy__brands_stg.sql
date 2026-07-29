with source as (
    select * from {{ source('raw_legacy', 'brands_stg') }}
),

renamed as (
    select
        brand_id as brand_id,
        brand_code as brand_code,
        brand_name as brand_name,
        brand_description as brand_description,
        brand_logo_url as brand_logo_url,
        brand_website as brand_website,
        parent_brand_id as parent_brand_id,
        is_private_label as is_private_label,
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
