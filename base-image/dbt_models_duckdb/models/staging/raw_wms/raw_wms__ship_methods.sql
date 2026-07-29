{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'SHIP_METHODS') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by shipping_method_id order by _loaded_at desc) as _rn
        from source
        where shipping_method_id is not null
    )
    where _rn = 1
)

select * from deduped
