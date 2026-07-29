-- Org Hierarchy Summary
-- Summarizes org hierarchy

with org_hierarchy as (
    select * from {{ ref('stg_hr__org_hierarchy') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    oh.level as org_level,
    count(distinct oh.employee_id) as employees_at_level,
    count(distinct oh.manager_id) as unique_managers,
    min(oh.effective_from) as earliest_effective,
    max(oh.effective_to) as latest_effective
from org_hierarchy oh
left join employees e on oh.employee_id = e.employee_id
group by 1
order by 1
