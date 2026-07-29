{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'ZONES') }}
),

deduped as (
    select *
    from source
    where zone_id is not null
    qualify row_number() over (partition by zone_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
