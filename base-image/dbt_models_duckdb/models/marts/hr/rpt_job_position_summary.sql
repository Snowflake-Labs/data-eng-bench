-- Job Position Summary
-- Summarizes job positions

with job_positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
)

select
    jp.position_id,
    jp.position_code,
    jp.position_title,
    d.department_name,
    jp.job_level,
    jp.min_salary,
    jp.max_salary,
    count(distinct e.employee_id) as employees_in_position,
    jp.created_at
from job_positions jp
left join departments d on jp.department_id = d.department_id
left join employees e on jp.position_id = e.position_id
group by 1, 2, 3, 4, 5, 6, 7, 9
