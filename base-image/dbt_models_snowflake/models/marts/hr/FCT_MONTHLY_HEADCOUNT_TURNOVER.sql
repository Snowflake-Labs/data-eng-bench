with months as (
    select distinct DATE_TRUNC('month', full_date) as month_date
    from {{ ref('stg_analytics__dim_date') }}
),
employee_activity as (
    select
        employee_id,
        hire_date,
        termination_date
    from {{ ref('stg_hr__employees') }}
)

select
    m.month_date,
    count(case when e.hire_date <= m.month_date and (e.termination_date is null or e.termination_date > m.month_date) then 1 end) as active_headcount,
    count(case when DATE_TRUNC('month', e.hire_date) = m.month_date then 1 end) as new_hires,
    count(case when DATE_TRUNC('month', e.termination_date) = m.month_date then 1 end) as terminations
from months m
cross join employee_activity e
group by 1
