{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.DIM_EMPLOYEE

with source as (
    select * from {{ source('analytics', 'DIM_EMPLOYEE') }}
),

renamed as (
    select
        employee_key,
        trim(employee_id) as employee_id,
        trim(employee_number) as employee_number,
        trim(employee_name) as employee_name,
        trim(department_name) as department_name,
        trim(position_title) as position_title,
        trim(manager_name) as manager_name,
        hire_date,
        is_active
    from source
)

select * from renamed
