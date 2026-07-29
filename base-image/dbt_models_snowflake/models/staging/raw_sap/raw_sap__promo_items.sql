{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'PROMO_ITEMS') }}
),

deduped as (
    select *
    from source
    where mapping_id is not null
    qualify row_number() over (partition by mapping_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
