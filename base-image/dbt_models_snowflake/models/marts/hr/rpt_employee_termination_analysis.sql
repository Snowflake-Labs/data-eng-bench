-- Employee Termination Analysis
-- Analyzes terminations

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    DATE_TRUNC('month', e.termination_date) as termination_month,
    d.department_name,
    e.employment_type,
    count(distinct e.employee_id) as terminations,
    avg(DATEDIFF(day, e.hire_date, e.termination_date)) as avg_tenure_days
from employees e
left join departments d on e.department_id = d.department_id
where e.termination_date is not null
group by 1, 2, 3
order by 1, 2
