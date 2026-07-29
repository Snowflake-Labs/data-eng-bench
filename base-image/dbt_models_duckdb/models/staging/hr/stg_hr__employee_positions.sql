{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.EMPLOYEE_POSITIONS

with source as (
    select * from {{ source('hr', 'EMPLOYEE_POSITIONS') }}
),

renamed as (
    select
        trim(assignment_id) as assignment_id,
        trim(employee_id) as employee_id,
        trim(position_id) as position_id,
        start_date,
        end_date,
        is_primary,
        created_at
    from source
)

select * from renamed
