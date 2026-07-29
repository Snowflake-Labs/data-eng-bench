{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'MARA_ATTR') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by attribute_id order by _loaded_at desc) as _rn
        from source
        where attribute_id is not null
    )
    where _rn = 1
)

select * from deduped
