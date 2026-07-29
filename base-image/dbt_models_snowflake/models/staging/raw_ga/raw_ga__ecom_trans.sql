{{
    config(
        materialized='view',
        tags=['staging', 'ga']
    )
}}

with source as (
    select * from {{ source('ga', 'ECOM_TRANS') }}
),

deduped as (
    select *
    from source
    where order_id is not null
    qualify row_number() over (partition by order_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
