{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.PAYROLL_DETAILS

with source as (
    select * from {{ source('hr', 'PAYROLL_DETAILS') }}
),

renamed as (
    select
        trim(detail_id) as detail_id,
        trim(payroll_run_id) as payroll_run_id,
        trim(employee_id) as employee_id,
        gross_pay,
        tax_deductions,
        other_deductions,
        net_pay,
        hours_worked,
        overtime_hours,
        created_at
    from source
)

select * from renamed
