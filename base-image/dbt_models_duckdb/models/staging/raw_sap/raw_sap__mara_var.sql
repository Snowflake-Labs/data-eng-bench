{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'MARA_VAR') }}
),

deduped as (
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by variant_id order by _loaded_at desc) as _rn
        from source
        where variant_id is not null
    )
    where _rn = 1
)

select * from deduped
