-- Employee Schedule Summary
-- Summarizes employee schedules

with employee_schedules as (
    select * from {{ ref('stg_hr__employee_schedules') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    es.shift_type,
    DATE_TRUNC(week, es.schedule_date) as schedule_week,
    count(distinct es.employee_id) as employees_scheduled,
    count(distinct es.schedule_id) as total_shifts,
    count(distinct es.location_id) as locations
from employee_schedules es
left join employees e on es.employee_id = e.employee_id
group by 1, 2
