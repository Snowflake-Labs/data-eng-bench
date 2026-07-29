{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'TRANSFERS') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by transfer_id order by _loaded_at desc) as _rn
        from source
        where transfer_id is not null
    )
    where _rn = 1
)

select * from deduped
