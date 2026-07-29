{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'INV_SNAPSHOT') }}
),

deduped as (
    select *
    from source
    where inventory_id is not null
    qualify row_number() over (partition by inventory_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
