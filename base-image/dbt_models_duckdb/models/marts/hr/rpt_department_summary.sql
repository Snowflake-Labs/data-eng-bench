-- Department Summary
-- Summarizes departments

with departments as (
    select * from {{ ref('stg_hr__departments') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    d.department_id,
    d.department_code,
    d.department_name,
    d.parent_department_id,
    parent.department_name as parent_department_name,
    mgr.first_name || ' ' || mgr.last_name as manager_name,
    count(distinct e.employee_id) as employee_count,
    d.created_at
from departments d
left join departments parent on d.parent_department_id = parent.department_id
left join employees mgr on d.manager_id = mgr.employee_id
left join employees e on d.department_id = e.department_id
group by 1, 2, 3, 4, 5, 6, 8
