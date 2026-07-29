{{
    config(
        materialized='view',
        tags=['staging', 'pos']
    )
}}

with source as (
    select * from {{ source('pos', 'TENDERS') }}
),

deduped as (
    select *
    from source
    where payment_id is not null
    qualify row_number() over (partition by payment_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
