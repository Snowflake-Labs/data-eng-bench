{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.EMPLOYEE_SCHEDULES

with source as (
    select * from {{ source('hr', 'EMPLOYEE_SCHEDULES') }}
),

renamed as (
    select
        trim(schedule_id) as schedule_id,
        trim(employee_id) as employee_id,
        schedule_date,
        trim(shift_type) as shift_type,
        start_time,
        end_time,
        trim(location_id) as location_id,
        created_at
    from source
)

select * from renamed
