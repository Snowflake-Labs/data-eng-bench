{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.TIME_ENTRIES

with source as (
    select * from {{ source('hr', 'TIME_ENTRIES') }}
),

renamed as (
    select
        trim(entry_id) as entry_id,
        trim(employee_id) as employee_id,
        entry_date,
        clock_in,
        clock_out,
        break_minutes,
        hours_worked,
        trim(entry_type) as entry_type,
        trim(status) as status,
        created_at
    from source
)

select * from renamed
