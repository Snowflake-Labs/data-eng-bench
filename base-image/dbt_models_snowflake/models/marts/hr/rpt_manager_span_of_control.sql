-- Manager Span of Control
-- Analyzes manager direct reports

with employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    e.manager_id,
    mgr.first_name || ' ' || mgr.last_name as manager_name,
    count(distinct e.employee_id) as direct_reports
from employees e
left join employees mgr on e.manager_id = mgr.employee_id
where e.manager_id is not null
group by 1, 2
order by 3 desc
