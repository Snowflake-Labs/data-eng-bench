{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.JOB_POSITIONS

with source as (
    select * from {{ source('hr', 'JOB_POSITIONS') }}
),

renamed as (
    select
        trim(position_id) as position_id,
        trim(position_code) as position_code,
        trim(position_title) as position_title,
        trim(department_id) as department_id,
        job_level,
        min_salary,
        max_salary,
        is_active,
        created_at
    from source
)

select * from renamed
