{{
    config(
        materialized='view',
        tags=['staging', 'wms']
    )
}}

with source as (
    select * from {{ source('wms', 'ADJUSTMENTS') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by adjustment_id order by _loaded_at desc) as _rn
        from source
        where adjustment_id is not null
    )
    where _rn = 1
)

select * from deduped
