{{
    config(
        materialized='view',
        tags=['staging', 'pos']
    )
}}

with source as (
    select * from {{ source('pos', 'COUPON_USAGE') }}
    where redemption_id is not null
)

select *
from source
qualify row_number() over (partition by redemption_id order by _loaded_at desc NULLS LAST) = 1
