-- Time Entry Summary
-- Summarizes time entries

with time_entries as (
    select * from {{ ref('stg_hr__time_entries') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    te.entry_type,
    te.status,
    date_trunc('week', te.entry_date) as entry_week,
    count(distinct te.employee_id) as unique_employees,
    count(distinct te.entry_id) as entry_count,
    sum(te.hours_worked) as total_hours,
    avg(te.hours_worked) as avg_hours_per_entry
from time_entries te
left join employees e on te.employee_id = e.employee_id
group by 1, 2, 3
