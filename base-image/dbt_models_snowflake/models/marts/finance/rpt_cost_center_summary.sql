-- Cost Center Summary
-- Summarizes cost centers

with cost_centers as (
    select * from {{ ref('stg_finance__cost_centers') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    cc.cost_center_id,
    cc.cost_center_code,
    cc.cost_center_name,
    e.first_name || ' ' || e.last_name as manager_name,
    cc.created_at
from cost_centers cc
left join employees e on cc.manager_id = e.employee_id
