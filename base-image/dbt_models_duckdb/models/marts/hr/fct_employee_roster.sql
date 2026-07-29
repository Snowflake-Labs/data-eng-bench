-- Employee Roster Fact Table
-- Comprehensive employee view with compensation analysis, tenure metrics,
-- organizational hierarchy, and performance capacity indicators

with employees as (
    select * from {{ ref('stg_hr__employees') }}
),

depts as (
    select * from {{ ref('stg_hr__departments') }}
),

positions as (
    select * from {{ ref('stg_hr__job_positions') }}
),

-- Calculate employee-level metrics
employee_metrics as (
    select
        e.employee_id,
        e.employee_number,
        e.first_name,
        e.last_name,
        concat(e.first_name, ' ', e.last_name) as full_name,
        e.email,
        e.phone,
        e.hire_date,
        e.termination_date,
        e.manager_id,
        e.department_id,
        e.position_id,
        e.employment_type,
        e.status,
        -- Tenure calculations
        date_diff('day', e.hire_date, current_date) as days_employed,
        round(date_diff('day', e.hire_date, current_date) / 365.0, 2) as years_employed,
        extract(year from e.hire_date) as hire_year,
        extract(month from e.hire_date) as hire_month,
        -- Anniversary tracking
        case 
            when extract(month from e.hire_date) = extract(month from current_date)
                 and extract(day from e.hire_date) = extract(day from current_date)
            then true else false 
        end as is_anniversary_today,
        case 
            when extract(month from e.hire_date) = extract(month from current_date)
            then true else false 
        end as has_anniversary_this_month
    from employees e
    where e.status = 'ACTIVE'
),

-- Manager lookup for reporting structure
managers as (
    select
        employee_id as manager_emp_id,
        concat(first_name, ' ', last_name) as manager_name,
        email as manager_email
    from employees
),

-- Direct report counts for each manager
direct_report_counts as (
    select
        manager_id,
        count(*) as direct_report_count
    from employees
    where status = 'ACTIVE' and manager_id is not null
    group by manager_id
),

-- Salary positioning within band
salary_analysis as (
    select
        em.employee_id,
        p.min_salary,
        p.max_salary,
        p.job_level,
        -- Compa-ratio simulation: position in salary band (mid-point assumed at 50%)
        case 
            when p.max_salary is not null and p.min_salary is not null 
                 and p.max_salary > p.min_salary
            then round((p.min_salary + (p.max_salary - p.min_salary) * 0.5), 2)
            else null 
        end as salary_midpoint,
        p.max_salary - p.min_salary as salary_range
    from employee_metrics em
    left join positions p on em.position_id = p.position_id
),

-- Final roster with all enrichments
final as (
    select
        em.employee_id,
        em.employee_number,
        em.full_name,
        em.first_name,
        em.last_name,
        em.email,
        em.phone,
        em.hire_date,
        em.hire_year,
        em.hire_month,
        em.days_employed,
        em.years_employed,
        em.is_anniversary_today,
        em.has_anniversary_this_month,
        em.employment_type,
        em.status,
        -- Department info
        d.department_id,
        d.department_name,
        d.department_code,
        -- Position info
        p.position_id,
        p.position_title,
        p.job_level,
        p.min_salary as position_min_salary,
        p.max_salary as position_max_salary,
        sa.salary_midpoint,
        sa.salary_range,
        -- Management hierarchy
        em.manager_id,
        m.manager_name,
        m.manager_email,
        coalesce(drc.direct_report_count, 0) as direct_report_count,
        case when drc.direct_report_count > 0 then true else false end as is_manager,
        -- Tenure categorization
        case
            when em.years_employed < 1 then 'New Hire'
            when em.years_employed < 3 then 'Developing'
            when em.years_employed < 7 then 'Experienced'
            else 'Veteran'
        end as tenure_category,
        -- Employment type flags
        case when em.employment_type = 'FULL_TIME' then true else false end as is_full_time,
        case when em.employment_type = 'PART_TIME' then true else false end as is_part_time,
        case when em.employment_type = 'CONTRACT' then true else false end as is_contractor
    from employee_metrics em
    left join depts d on em.department_id = d.department_id
    left join positions p on em.position_id = p.position_id
    left join managers m on em.manager_id = m.manager_emp_id
    left join direct_report_counts drc on em.employee_id = drc.manager_id
    left join salary_analysis sa on em.employee_id = sa.employee_id
)

select * from final
order by department_name, full_name