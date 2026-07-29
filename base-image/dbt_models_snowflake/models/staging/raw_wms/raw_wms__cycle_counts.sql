{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'CYCLE_COUNTS') }}
)

select * from source
where count_id is not null
qualify row_number() over (partition by count_id order by _loaded_at desc NULLS LAST) = 1
