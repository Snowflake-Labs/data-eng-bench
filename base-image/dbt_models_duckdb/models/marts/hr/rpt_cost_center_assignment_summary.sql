-- Cost Center Assignment Summary
-- Summarizes cost center assignments

with cost_center_assignments as (
    select * from {{ ref('stg_hr__cost_center_assignments') }}
),

cost_centers as (
    select * from {{ ref('stg_finance__cost_centers') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    cc.cost_center_code,
    cc.cost_center_name,
    count(distinct cca.employee_id) as employees_assigned,
    sum(cca.allocation_percentage) as total_allocation_pct,
    avg(cca.allocation_percentage) as avg_allocation_pct
from cost_center_assignments cca
left join cost_centers cc on cca.cost_center_id = cc.cost_center_id
left join employees e on cca.employee_id = e.employee_id
where cca.effective_to is null or cca.effective_to > current_date
group by 1, 2
