{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'PA0002') }}
),

deduped as (
    select *
    from source
    where employee_id is not null
    qualify row_number() over (partition by employee_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
