{{
    config(
        materialized='view',
        tags=['staging', 'pos']
    )
}}

with source as (
    select * from {{ source('pos', 'DISCOUNTS') }}
    where _id is not null
)

select *
from source
qualify row_number() over (partition by _id order by _loaded_at desc NULLS LAST) = 1
