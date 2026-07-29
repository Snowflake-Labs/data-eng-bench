{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.EMPLOYEES

with source as (
    select * from {{ source('hr', 'EMPLOYEES') }}
),

renamed as (
    select
        trim(employee_id) as employee_id,
        trim(employee_number) as employee_number,
        trim(first_name) as first_name,
        trim(last_name) as last_name,
        trim(email) as email,
        trim(phone) as phone,
        hire_date,
        termination_date,
        trim(manager_id) as manager_id,
        trim(department_id) as department_id,
        trim(position_id) as position_id,
        trim(employment_type) as employment_type,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
