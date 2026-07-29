{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'CEPC') }}
),

deduped as (
    select *
    from source
    where profit_center_id is not null
    qualify row_number() over (partition by profit_center_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
