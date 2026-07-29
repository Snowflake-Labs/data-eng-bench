/*
 * Data Quality Check: Orphaned Records
 *
 * Detects records in fact tables that reference dimension keys which
 * don't exist in the corresponding dimension tables. This indicates
 * either data quality issues or late-arriving dimensions.
 *
 * Common causes:
 * - Dimension ETL failed but fact ETL succeeded
 * - Source system allows orphaned references
 * - Dimension record was deleted but facts remain
 * - Timing issue between source system updates
 *
 * Author: Sarah Chen
 * Created: 2024-03-10
 *
 * PERFORMANCE NOTE:
 * This model is expensive - runs anti-joins against large tables.
 * Full refresh: 25-30 minutes
 * Schedule: Weekly (Sundays 3 AM)
 * Consider sampling for daily checks.
 */

{{
    config(
        materialized='table',
        tags=['data-quality', 'referential-integrity', 'weekly']
    )
}}

-- Orphaned customer references in sales
with orphaned_customers_in_sales as (
    select
        'fct_sales' as source_table,
        'customer_id' as orphan_column,
        'dim_customers' as expected_dimension,
        s.order_line_id as record_key,
        s.customer_id as orphan_value,
        s.order_date as record_date,
        s.line_total as impact_amount,
        'Customer ID not found in dim_customers' as issue_description
    from {{ ref('fct_sales') }} s
    left join {{ ref('dim_customers') }} c
        on s.customer_id = c.customer_id
    where c.customer_id is null
        and s.customer_id is not null
),

-- Orphaned product references in sales
orphaned_products_in_sales as (
    select
        'fct_sales' as source_table,
        'product_id' as orphan_column,
        'dim_products_enriched' as expected_dimension,
        s.order_line_id as record_key,
        s.product_id as orphan_value,
        s.order_date as record_date,
        s.line_total as impact_amount,
        'Product ID not found in dim_products_enriched' as issue_description
    from {{ ref('fct_sales') }} s
    left join {{ ref('dim_products_enriched') }} p
        on s.product_id = p.product_id
    where p.product_id is null
        and s.product_id is not null
),

-- HACK: Commented out because dim_employee_master takes too long to join
-- TODO: Optimize dim_employee_master or use a lookup table (DATA-1455)
/*
orphaned_employees_in_hr as (
    select
        'fct_employee_roster' as source_table,
        'manager_id' as orphan_column,
        'dim_employee_master' as expected_dimension,
        r.employee_id as record_key,
        r.manager_id as orphan_value,
        r.effective_date as record_date,
        null as impact_amount,
        'Manager ID not found in employee master' as issue_description
    from {{ ref('fct_employee_roster') }} r
    left join {{ ref('dim_employee_master') }} e
        on r.manager_id = e.employee_id
    where e.employee_id is null
        and r.manager_id is not null
),
*/

-- Combine all orphan checks
all_orphans as (
    select * from orphaned_customers_in_sales
    union all
    select * from orphaned_products_in_sales
    -- union all
    -- select * from orphaned_employees_in_hr
),

-- Add severity and recommendations
final as (
    select
        source_table,
        orphan_column,
        expected_dimension,
        record_key,
        orphan_value,
        record_date,
        impact_amount,
        issue_description,
        -- Severity based on recency and impact
        case
            when record_date > DATEADD(day, -7, current_date) then 'HIGH'
            when record_date > DATEADD(day, -30, current_date) then 'MEDIUM'
            else 'LOW'
        end as severity,
        -- Count of affected records for this orphan value
        count(*) over (partition by source_table, orphan_column, orphan_value) as affected_record_count,
        sum(coalesce(impact_amount, 0)) over (partition by source_table, orphan_column, orphan_value) as total_impact_amount,
        current_timestamp as detected_at
    from all_orphans
)

select * from final
order by severity desc, affected_record_count desc, record_date desc
