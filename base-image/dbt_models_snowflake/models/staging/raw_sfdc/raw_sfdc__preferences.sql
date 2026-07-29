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
    select *
    from source
    where preference_id is not null
    qualify row_number() over (partition by preference_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
