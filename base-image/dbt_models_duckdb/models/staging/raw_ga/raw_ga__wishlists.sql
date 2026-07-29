{{
    config(
        materialized='view',
        tags=['staging', 'ga']
    )
}}

with source as (
    select * from {{ source('ga', 'WISHLISTS') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by wishlist_item_id order by _loaded_at desc) as _rn
        from source
        where wishlist_item_id is not null
    )
    where _rn = 1
)

select * from deduped
