{{
    config(
        materialized='view',
        tags=['staging', 'legacy']
    )
}}

with source as (
    select * from {{ source('legacy', 'CATCOD') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by category_id order by _loaded_at desc) as _rn
        from source
        where category_id is not null
    )
    where _rn = 1
)

select * from deduped
