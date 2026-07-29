{{
    config(
        materialized='view',
        tags=['staging', 'ga']
    )
}}

with source as (
    select * from {{ source('ga', 'AUDIENCES') }}
),

deduped as (
    select *
    from (
        select *,
            row_number() over (partition by segment_id order by _loaded_at desc NULLS LAST) as _rn
        from source
        where segment_id is not null
    )
    where _rn = 1
    QUALIFY ROW_NUMBER() OVER (PARTITION BY segment_id ORDER BY _loaded_at DESC NULLS LAST) = 1
)

select * from deduped
