-- HR Salary Distribution
-- Analyzes salary distribution

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

employee_compensation as (
    select * from {{ ref('stg_hr__employee_compensation') }}
)

select
    d.department_name,
    count(distinct e.employee_id) as employee_count,
    min(ec.amount) as min_salary,
    max(ec.amount) as max_salary,
    avg(ec.amount) as avg_salary,
    percentile_cont(0.25) within group (order by ec.amount) as p25_salary,
    percentile_cont(0.50) within group (order by ec.amount) as median_salary,
    percentile_cont(0.75) within group (order by ec.amount) as p75_salary
from employees e
left join departments d on e.department_id = d.department_id
left join employee_compensation ec on e.employee_id = ec.employee_id
where e.status = 'ACTIVE'
group by 1
