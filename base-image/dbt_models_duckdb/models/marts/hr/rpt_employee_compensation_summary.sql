-- Employee Compensation Summary
-- Summarizes compensation

with employee_compensation as (
    select * from {{ ref('stg_hr__employee_compensation') }}
),

employees as (
    select * from {{ ref('stg_hr__employees') }}
)

select
    ec.compensation_type,
    ec.currency_code,
    ec.frequency,
    count(distinct ec.employee_id) as employee_count,
    sum(ec.amount) as total_compensation,
    avg(ec.amount) as avg_compensation,
    min(ec.amount) as min_compensation,
    max(ec.amount) as max_compensation
from employee_compensation ec
left join employees e on ec.employee_id = e.employee_id
where ec.effective_to is null or ec.effective_to > current_date
group by 1, 2, 3
