{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.DEPARTMENTS

with source as (
    select * from {{ source('hr', 'DEPARTMENTS') }}
),

renamed as (
    select
        trim(department_id) as department_id,
        trim(department_code) as department_code,
        trim(department_name) as department_name,
        trim(parent_department_id) as parent_department_id,
        trim(manager_id) as manager_id,
        is_active,
        created_at
    from source
)

select * from renamed
