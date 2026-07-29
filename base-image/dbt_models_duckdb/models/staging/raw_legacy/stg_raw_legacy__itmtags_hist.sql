with source as (
    select * from {{ source('raw_legacy', 'itmtags_hist') }}
),

renamed as (
    select
        tag_id as tag_id,
        product_id as product_id,
        tag_name as tag_name,
        tag_type as tag_type,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _archived_at as _archived_at
    from source
)

select * from renamed
