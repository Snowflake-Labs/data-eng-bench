{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.EMPLOYEE_DEPARTMENTS

with source as (
    select * from {{ source('hr', 'EMPLOYEE_DEPARTMENTS') }}
),

renamed as (
    select
        trim(assignment_id) as assignment_id,
        trim(employee_id) as employee_id,
        trim(department_id) as department_id,
        start_date,
        end_date,
        created_at
    from source
)

select * from renamed
