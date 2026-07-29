{{
    config(
        materialized='view',
        tags=['staging', 'ga']
    )
}}

with source as (
    select * from {{ source('ga', 'CONSENT_LOG') }}
),

deduped as (
    select *
    from source
    where _id is not null
    qualify row_number() over (partition by _id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
