{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'PC2') }}
),

deduped as (
    select *
    from source
    where payroll_run_id is not null
    qualify row_number() over (partition by payroll_run_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
