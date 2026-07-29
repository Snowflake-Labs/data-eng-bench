{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'MARC') }}
),

deduped as (
    select *
    from source
    where _id is not null
    qualify row_number() over (partition by _id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
