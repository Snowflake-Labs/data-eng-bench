{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'HRP1000_DEP') }}
),

deduped as (
    select *
    from source
    where department_id is not null
    qualify row_number() over (partition by department_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
