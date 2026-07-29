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
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by order_id order by _loaded_at desc) as _rn
        from source
        where order_id is not null
    )
    where _rn = 1
)

select * from deduped
