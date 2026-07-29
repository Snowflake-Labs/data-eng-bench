-- HR Tenure Analysis Report
-- Provides comprehensive tenure analytics by department including distribution,
-- retention risk indicators, and manager-level insights

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

departments as (
    select * from {{ ref('stg_hr__departments') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

-- Calculate tenure for each active employee
employee_tenure as (
    select
        e.employee_id,
        e.department_id,
        e.position_id,
        e.manager_id,
        e.employment_type,
        e.hire_date,
        date_diff('day', e.hire_date, current_date) / 365.0 as tenure_years,
        case
            when date_diff('day', e.hire_date, current_date) < 90 then 'New Hire (0-3 months)'
            when date_diff('day', e.hire_date, current_date) / 365.0 < 1 then 'First Year'
            when date_diff('day', e.hire_date, current_date) / 365.0 < 2 then '1-2 Years'
            when date_diff('day', e.hire_date, current_date) / 365.0 < 5 then '2-5 Years'
            when date_diff('day', e.hire_date, current_date) / 365.0 < 10 then '5-10 Years'
            else '10+ Years'
        end as tenure_band,
        -- Early attrition risk: employees in their first year are higher risk
        case 
            when date_diff('day', e.hire_date, current_date) / 365.0 < 1 then true 
            else false 
        end as is_first_year_employee
    from employees e
    where e.status = 'ACTIVE'
),

-- Department-level aggregations
department_metrics as (
    select
        et.department_id,
        count(et.employee_id) as headcount,
        count(case when et.employment_type = 'FULL_TIME' then 1 end) as full_time_count,
        count(case when et.employment_type = 'PART_TIME' then 1 end) as part_time_count,
        count(case when et.employment_type = 'CONTRACT' then 1 end) as contractor_count,
        avg(et.tenure_years) as avg_tenure_years,
        min(et.tenure_years) as min_tenure_years,
        max(et.tenure_years) as max_tenure_years,
        percentile_cont(0.5) within group (order by et.tenure_years) as median_tenure_years,
        stddev(et.tenure_years) as tenure_std_dev,
        count(case when et.is_first_year_employee then 1 end) as first_year_employees,
        count(distinct et.manager_id) as unique_managers,
        -- Tenure distribution counts
        count(case when et.tenure_band = 'New Hire (0-3 months)' then 1 end) as new_hires,
        count(case when et.tenure_band = '1-2 Years' then 1 end) as tenure_1_2_years,
        count(case when et.tenure_band = '2-5 Years' then 1 end) as tenure_2_5_years,
        count(case when et.tenure_band = '5-10 Years' then 1 end) as tenure_5_10_years,
        count(case when et.tenure_band = '10+ Years' then 1 end) as tenure_10_plus_years
    from employee_tenure et
    group by et.department_id
),

-- Company-wide benchmarks for comparison
company_benchmarks as (
    select
        avg(tenure_years) as company_avg_tenure,
        percentile_cont(0.5) within group (order by tenure_years) as company_median_tenure,
        count(*) as total_company_headcount
    from employee_tenure
),

-- Final report combining all metrics
final as (
    select
        d.department_id,
        d.department_name,
        d.department_code,
        dm.headcount,
        dm.full_time_count,
        dm.part_time_count,
        dm.contractor_count,
        round(dm.avg_tenure_years, 2) as avg_tenure_years,
        round(dm.median_tenure_years, 2) as median_tenure_years,
        round(dm.min_tenure_years, 2) as min_tenure_years,
        round(dm.max_tenure_years, 2) as max_tenure_years,
        round(dm.tenure_std_dev, 2) as tenure_std_dev,
        dm.unique_managers,
        round(dm.headcount::float / nullif(dm.unique_managers, 0), 1) as avg_span_of_control,
        -- Retention risk metrics
        dm.first_year_employees,
        round(100.0 * dm.first_year_employees / nullif(dm.headcount, 0), 1) as first_year_pct,
        -- Tenure distribution
        dm.new_hires,
        dm.tenure_1_2_years,
        dm.tenure_2_5_years,
        dm.tenure_5_10_years,
        dm.tenure_10_plus_years,
        -- Comparison to company average
        round(cb.company_avg_tenure, 2) as company_avg_tenure,
        round(dm.avg_tenure_years - cb.company_avg_tenure, 2) as tenure_vs_company_avg,
        case
            when dm.avg_tenure_years < cb.company_avg_tenure * 0.7 then 'High Turnover Risk'
            when dm.avg_tenure_years < cb.company_avg_tenure * 0.9 then 'Below Average'
            when dm.avg_tenure_years > cb.company_avg_tenure * 1.3 then 'Very Stable'
            when dm.avg_tenure_years > cb.company_avg_tenure * 1.1 then 'Above Average'
            else 'Average'
        end as tenure_health_indicator,
        -- Percentage of company headcount
        round(100.0 * dm.headcount / nullif(cb.total_company_headcount, 0), 1) as pct_of_company_headcount
    from department_metrics dm
    join departments d on dm.department_id = d.department_id
    cross join company_benchmarks cb
)

select * from final
order by headcount desc