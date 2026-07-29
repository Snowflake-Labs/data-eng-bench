{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'HRP1000') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by assignment_id order by _loaded_at desc) as _rn
        from source
        where assignment_id is not null
    )
    where _rn = 1
)

select * from deduped
