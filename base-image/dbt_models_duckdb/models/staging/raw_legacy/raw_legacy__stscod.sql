{{
    config(
        materialized='view',
        tags=['staging', 'legacy']
    )
}}

with source as (
    select * from {{ source('legacy', 'STSCOD') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by status_code_id order by _loaded_at desc) as _rn
        from source
        where status_code_id is not null
    )
    where _rn = 1
)

select * from deduped
