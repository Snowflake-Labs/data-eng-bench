with source as (
    select * from {{ source('raw_ga', 'wishlists') }}
),

renamed as (
    select
        wishlist_item_id as wishlist_item_id,
        wishlist_id as wishlist_id,
        variant_id as variant_id,
        added_at as added_at,
        notes as notes,
        priority as priority,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
