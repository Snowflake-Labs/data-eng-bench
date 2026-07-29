{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'MARA_VAR') }}
),

deduped as (
    select *
    from source
    where variant_id is not null
    qualify row_number() over (partition by variant_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
