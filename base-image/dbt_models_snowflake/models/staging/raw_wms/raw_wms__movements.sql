{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'MOVEMENTS') }}
),

deduped as (
    select
        * exclude (_rn)
    from (
        select *,
            row_number() over (partition by _id order by _loaded_at desc NULLS LAST) as _rn
        from source
        where _id is not null
    )
    qualify _rn = 1
)

select * from deduped
