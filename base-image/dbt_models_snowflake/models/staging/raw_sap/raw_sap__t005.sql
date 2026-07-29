{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'T005') }}
),

deduped as (
    select *
    from source
    where country_id is not null
    qualify row_number() over (partition by country_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
