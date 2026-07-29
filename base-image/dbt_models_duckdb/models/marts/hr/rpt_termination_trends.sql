-- HR Termination Trends
-- Analyzes termination trends

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    d.department_name,
    date_trunc('month', e.termination_date) as termination_month,
    count(distinct e.employee_id) as terminations,
    avg(date_diff('day', e.hire_date, e.termination_date)) as avg_tenure_days
from employees e
left join departments d on e.department_id = d.department_id
where e.termination_date is not null
group by 1, 2