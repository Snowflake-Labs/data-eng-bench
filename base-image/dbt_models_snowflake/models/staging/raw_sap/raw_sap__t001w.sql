{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'T001W') }}
),

deduped as (
    select *
    from source
    where warehouse_id is not null
    qualify row_number() over (partition by warehouse_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
