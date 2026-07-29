{{
    config(
        materialized='view',
        tags=['staging', 'sfdc']
    )
}}

with source as (
    select * from {{ source('sfdc', 'PREFERENCES') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by preference_id order by _loaded_at desc) as _rn
        from source
        where preference_id is not null
    )
    where _rn = 1
)

select * from deduped
