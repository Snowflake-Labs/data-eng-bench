-- Employment Type Distribution
-- Employees by employment type

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    e.employment_type,
    e.status,
    d.department_name,
    count(distinct e.employee_id) as employee_count
from employees e
left join departments d on e.department_id = d.department_id
group by 1, 2, 3
