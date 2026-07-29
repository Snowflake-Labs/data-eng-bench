with employees as (
    select * from {{ ref('stg_hr__employees') }}
),
positions as (
    select * from {{ ref('stg_hr__job_positions') }}
)

select
    p.position_title,
    p.min_salary,
    p.max_salary,
    avg((p.min_salary + p.max_salary) / 2) as avg_midpoint_salary,
    count(e.employee_id) as employee_count
from employees e
join positions p on e.position_id = p.position_id
where e.status = 'ACTIVE'
group by 1, 2, 3
