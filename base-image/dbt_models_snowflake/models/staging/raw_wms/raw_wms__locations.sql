{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'LOCATIONS') }}
),

deduped as (
    select *
    from (
        select *,
            row_number() over (partition by location_id order by _loaded_at desc NULLS LAST) as _rn
        from source
        where location_id is not null
    )
    where _rn = 1
    qualify row_number() over (partition by location_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
