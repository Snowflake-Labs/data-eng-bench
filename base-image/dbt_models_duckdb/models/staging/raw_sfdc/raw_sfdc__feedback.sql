{{
    config(
        materialized='view',
        tags=['staging', 'sfdc']
    )
}}

with source as (
    select * from {{ source('sfdc', 'FEEDBACK') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by review_id order by _loaded_at desc) as _rn
        from source
        where review_id is not null
    )
    where _rn = 1
)

select * from deduped
