{{
    config(
        materialized='view',
        tags=['staging', 'ga']
    )
}}

with source as (
    select * from {{ source('ga', 'PROMO_CODES') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by coupon_id order by _loaded_at desc) as _rn
        from source
        where coupon_id is not null
    )
    where _rn = 1
)

select * from deduped
