{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.PAYROLL_RUNS

with source as (
    select * from {{ source('hr', 'PAYROLL_RUNS') }}
),

renamed as (
    select
        trim(payroll_run_id) as payroll_run_id,
        trim(payroll_period) as payroll_period,
        period_start,
        period_end,
        pay_date,
        trim(status) as status,
        total_gross,
        total_net,
        employee_count,
        created_at
    from source
)

select * from renamed
