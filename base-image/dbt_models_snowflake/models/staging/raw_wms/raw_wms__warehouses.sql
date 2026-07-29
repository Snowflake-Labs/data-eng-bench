{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'WAREHOUSES') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by warehouse_id order by _loaded_at desc NULLS LAST) as _rn
        from source
        where warehouse_id is not null
    )
    where _rn = 1
)

select * from deduped
