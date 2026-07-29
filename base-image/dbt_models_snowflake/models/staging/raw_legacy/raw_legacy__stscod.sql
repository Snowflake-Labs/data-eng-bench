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
    select *
    from source
    where status_code_id is not null
    qualify row_number() over (partition by status_code_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
