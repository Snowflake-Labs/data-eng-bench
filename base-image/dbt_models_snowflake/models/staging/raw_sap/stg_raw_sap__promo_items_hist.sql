with source as (
    select * from {{ source('raw_sap', 'promo_items_hist') }}
),

renamed as (
    select
        mapping_id as mapping_id,
        promotion_id as promotion_id,
        product_id as product_id,
        category_id as category_id,
        brand_id as brand_id,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id, _row_number as _row_number,
        _row_hash as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
