-- Payroll Summary
-- Summarizes payroll runs

with payroll_runs as (
    select * from {{ ref('stg_hr__payroll_runs') }}
),

payroll_details as (
    select * from {{ ref('stg_hr__payroll_details') }}
)

select
    pr.payroll_run_id,
    pr.payroll_period,
    pr.period_start,
    pr.period_end,
    pr.pay_date,
    pr.status,
    pr.total_gross,
    pr.total_net,
    count(distinct pd.employee_id) as employees_paid,
    sum(pd.hours_worked) as total_hours_worked,
    sum(pd.tax_deductions) as total_tax_deductions
from payroll_runs pr
left join payroll_details pd on pr.payroll_run_id = pd.payroll_run_id
group by 1, 2, 3, 4, 5, 6, 7, 8
