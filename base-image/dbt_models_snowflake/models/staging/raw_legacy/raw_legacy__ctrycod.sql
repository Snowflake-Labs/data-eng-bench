{{
    config(
        materialized='view',
        tags=['staging', 'legacy']
    )
}}

with source as (
    select * from {{ source('legacy', 'CTRYCOD') }}
),

deduped as (
    select *
    from source
    where country_id is not null
    qualify row_number() over (partition by country_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
