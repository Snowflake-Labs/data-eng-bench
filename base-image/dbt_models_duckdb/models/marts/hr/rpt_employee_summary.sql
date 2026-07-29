-- Employee Summary
-- Summarizes employees

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

job_positions as (
    select * from {{ ref('stg_hr__job_positions') }}
)

select
    e.employee_id,
    e.employee_number,
    e.first_name,
    e.last_name,
    e.email,
    d.department_name,
    jp.position_title,
    e.employment_type,
    e.status,
    e.hire_date,
    e.termination_date,
    date_diff('day', e.hire_date, coalesce(e.termination_date, current_date)) as tenure_days
from employees e
left join departments d on e.department_id = d.department_id
left join job_positions jp on e.position_id = jp.position_id
