{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'CATSDB') }}
),

deduped as (
    select *
    from source
    where entry_id is not null
    qualify row_number() over (partition by entry_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
