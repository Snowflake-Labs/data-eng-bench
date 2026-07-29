{{
    config(
        materialized='view',
        tags=['staging', 'pos']
    )
}}

with source as (
    select * from {{ source('pos', 'COUPON_USAGE') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by redemption_id order by _loaded_at desc) as _rn
        from source
        where redemption_id is not null
    )
    where _rn = 1
)

select * from deduped
