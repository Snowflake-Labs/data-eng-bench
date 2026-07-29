with employees as (
    select * from {{ ref('stg_hr__employees') }}
),
positions as (
    select * from {{ ref('stg_hr__job_positions') }}
)

select 
    p.position_title,
    count(e.employee_id) as employee_count,
    avg(p.min_salary) as avg_min_salary,
    avg(p.max_salary) as avg_max_salary
from employees e
join positions p on e.position_id = p.position_id
group by 1