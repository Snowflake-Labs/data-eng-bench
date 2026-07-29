-- Employee Department History
-- Tracks department changes

with employee_departments as (
    select * from {{ ref('stg_hr__employee_departments') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    ed.employee_id,
    e.first_name || ' ' || e.last_name as employee_name,
    d.department_name,
    ed.start_date,
    ed.end_date,
    date_diff('day', ed.start_date, coalesce(ed.end_date, current_date)) as days_in_department
from employee_departments ed
left join departments d on ed.department_id = d.department_id
left join employees e on ed.employee_id = e.employee_id
