{{
    config(
        materialized='view',
        tags=['staging', 'legacy']
    )
}}

with source as (
    select * from {{ source('legacy', 'BRANDS') }}
),

deduped as (
    select *
    from source
    where brand_id is not null
    qualify row_number() over (partition by brand_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
