-- =============================================================================
-- dim_employee_master
-- =============================================================================
-- Employee master dimension. PII data - handle with care!
-- Data sources: SAP HR (PA0001, PA0002 infotypes)
--
-- Author: HR Analytics Team
-- Last updated: 2024-08-15
--
-- GDPR/CCPA Note: This table contains PII. Access restricted to HR role.
-- Retention: 7 years per company policy
--
-- Performance: 3 min, ~15K employees
-- =============================================================================

-- TODO: Add department name lookup (currently only have dept ID)
-- TODO: Add cost center for finance reporting
-- FIXME: manager_id sometimes references terminated employees
-- FIXME: Some employees appear twice due to Workday/SAP sync issues
-- HACK: Using FULL OUTER JOIN because neither system is complete source of truth

with org_assignment as (
    select * from {{ ref('stg_raw_sap__pa0001') }}
),
personal_data as (
    select * from {{ ref('stg_raw_sap__pa0002') }}
),

-- Combine personal and organizational data
joined_data as (
    select
        coalesce(p.employee_id, o.employee_id) as employee_id,
        coalesce(p.employee_number, o.employee_number) as employee_number,
        -- Personal Data
        p.first_name,
        p.last_name,
        concat(p.first_name, ' ', p.last_name) as display_name,
        p.email,
        p.phone,
        -- Org Assignment
        o.department_id,
        o.position_id,
        o.manager_id,
        o.employment_type,
        -- Dates & Status (handle multiple date formats: MM/DD/YYYY, YYYY-MM-DD, YYYYMMDD, Unix timestamp)
        case
            when coalesce(p.hire_date, o.hire_date) is null then null
            -- Unix timestamp (numeric string with decimal)
            when regexp_matches(coalesce(p.hire_date, o.hire_date), '^\d+\.\d+$')
                then epoch_ms(cast(cast(coalesce(p.hire_date, o.hire_date) as double) * 1000 as bigint))::date
            -- YYYYMMDD format
            when regexp_matches(coalesce(p.hire_date, o.hire_date), '^\d{8}$')
                then strptime(coalesce(p.hire_date, o.hire_date), '%Y%m%d')::date
            -- MM/DD/YYYY format
            when regexp_matches(coalesce(p.hire_date, o.hire_date), '^\d{2}/\d{2}/\d{4}$')
                then strptime(coalesce(p.hire_date, o.hire_date), '%m/%d/%Y')::date
            -- YYYY-MM-DD format (standard)
            else try_cast(coalesce(p.hire_date, o.hire_date) as date)
        end as hire_date,
        case
            when coalesce(p.termination_date, o.termination_date) is null then null
            -- Unix timestamp (numeric string with decimal)
            when regexp_matches(coalesce(p.termination_date, o.termination_date), '^\d+\.\d+$')
                then epoch_ms(cast(cast(coalesce(p.termination_date, o.termination_date) as double) * 1000 as bigint))::date
            -- YYYYMMDD format
            when regexp_matches(coalesce(p.termination_date, o.termination_date), '^\d{8}$')
                then strptime(coalesce(p.termination_date, o.termination_date), '%Y%m%d')::date
            -- MM/DD/YYYY format
            when regexp_matches(coalesce(p.termination_date, o.termination_date), '^\d{2}/\d{2}/\d{4}$')
                then strptime(coalesce(p.termination_date, o.termination_date), '%m/%d/%Y')::date
            -- YYYY-MM-DD format (standard)
            else try_cast(coalesce(p.termination_date, o.termination_date) as date)
        end as termination_date,
        coalesce(p.status, o.status, 'UNKNOWN') as status,
        -- Meta
        p.created_at as profile_created_at,
        p.updated_at as profile_updated_at
    from personal_data p
    full outer join org_assignment o on p.employee_id = o.employee_id
)

select 
    employee_id,
    employee_number,
    first_name,
    last_name,
    display_name,
    lower(email) as email,
    phone,
    department_id,
    position_id,
    manager_id,
    employment_type,
    hire_date,
    termination_date,
    -- Tenure Calculation
    case 
        when termination_date is not null then date_diff('day', hire_date, termination_date) / 365.0
        else date_diff('day', hire_date, current_date) / 365.0 
    end as tenure_years,
    -- Status Enrichment
    status,
    case 
        when status = 'ACTIVE' then true 
        else false 
    end as is_active,
    case
        when hire_date > current_date - interval '90 days' then true
        else false
    end as is_new_hire,
    profile_updated_at as last_updated
from joined_data
where employee_id is not null