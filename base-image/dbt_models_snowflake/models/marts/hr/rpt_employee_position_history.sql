-- Employee Position History
-- Tracks position changes

with employee_positions as (
    select * from {{ ref('stg_hr__employee_positions') }}
),

job_positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    ep.employee_id,
    e.first_name || ' ' || e.last_name as employee_name,
    jp.position_title,
    ep.start_date,
    ep.end_date,
    ep.is_primary,
    DATEDIFF(day, ep.start_date, coalesce(ep.end_date, current_date)) as days_in_position
from employee_positions ep
left join job_positions jp on ep.position_id = jp.position_id
left join employees e on ep.employee_id = e.employee_id
