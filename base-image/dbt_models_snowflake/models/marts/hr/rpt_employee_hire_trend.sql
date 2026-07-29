-- Employee Hire Trend
-- Tracks hiring over time

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    DATE_TRUNC('month', e.hire_date) as hire_month,
    d.department_name,
    e.employment_type,
    count(distinct e.employee_id) as new_hires
from employees e
left join departments d on e.department_id = d.department_id
group by 1, 2, 3
order by 1, 2
