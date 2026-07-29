{{
    config(
        materialized='table',
        tags=['mart', 'finance', 'revenue']
    )
}}

/*
================================================================================
fact_revenue.sql

FINANCE CRITICAL MODEL - Changes require CFO approval
Contact: finance-analytics@company.com

Author: Finance Analytics Team
Created: 2023-02-01
Modified: 2024-09-30

Daily revenue aggregation. This feeds the executive dashboard, board reports,
and SEC filings. Be VERY careful making changes.

IMPORTANT: This model uses CASH BASIS accounting. For accrual basis, see
the separate fct_revenue_accrual model (not yet implemented).

AUDIT TRAIL:
- 2024-09-30: Added source_system breakout per auditor request
- 2024-06-15: Fixed discount calculation (was double-counting)
- 2024-03-01: Added cancellation rate metric
- 2023-12-20: Currency conversion hotfix

Performance: Full refresh 15 min, ~5M rows
SLA: Must complete by 4 AM EST for morning finance reports
Memory: 128GB peak, uses 2XL warehouse

RECONCILIATION NOTES:
- Should match Oracle GL within 0.1%
- Monthly variance report: Confluence/Finance/Revenue-Recon
================================================================================
*/

-- TODO: Add accrual basis revenue recognition (ASC 606)
-- TODO: Add deferred revenue calculation
-- FIXME: Exchange rate is from order date, should be settlement date
-- HACK: Hardcoded exchange rate fallback for currencies missing from rate table
-- BUG: Known ~$500 daily variance with GL due to timing. Ticket FIN-892.

with daily_sales as (

    select
        order_date,
        currency_code,
        source_system,

        -- Order counts
        count(distinct order_id) as total_orders,
        count(distinct customer_id) as unique_customers,
        count(order_line_id) as total_line_items,

        -- Revenue metrics
        sum(extended_price) as gross_revenue,
        sum(discount_amount) as total_discounts,
        sum(extended_price - discount_amount) as net_revenue,
        sum(tax_amount) as total_tax,
        sum(line_total) as total_revenue,

        -- Average metrics
        avg(unit_price) as avg_unit_price,
        avg(extended_price) as avg_line_value,

        -- Quantity metrics
        sum(quantity_ordered) as total_units_ordered,
        sum(quantity_shipped) as total_units_shipped,

        -- Fulfillment metrics
        count(case when is_fully_shipped then 1 end) as fully_shipped_lines,
        count(case when is_cancelled then 1 end) as cancelled_lines

    from {{ ref('fct_sales') }}
    where order_date is not null
    group by
        order_date,
        currency_code,
        source_system

),

final as (

    select
        -- Date dimension
        order_date,
        extract(year from order_date) as year,
        extract(month from order_date) as month,
        extract(quarter from order_date) as quarter,
        extract(dayofweek from order_date) as day_of_week,
        extract(week from order_date) as week_of_year,

        -- Dimensions
        currency_code,
        source_system,

        -- Counts
        total_orders,
        unique_customers,
        total_line_items,

        -- Revenue
        gross_revenue,
        total_discounts,
        net_revenue,
        total_tax,
        total_revenue,

        -- Averages
        avg_unit_price,
        avg_line_value,
        case
            when total_orders > 0
            then total_revenue / total_orders
            else 0
        end as avg_order_value,

        -- Units
        total_units_ordered,
        total_units_shipped,

        -- Fulfillment rates
        case
            when total_line_items > 0
            then (fully_shipped_lines::decimal / total_line_items::decimal)
            else 0
        end as fulfillment_rate,

        case
            when total_line_items > 0
            then (cancelled_lines::decimal / total_line_items::decimal)
            else 0
        end as cancellation_rate,

        -- Discount rate
        case
            when gross_revenue > 0
            then (total_discounts / gross_revenue)
            else 0
        end as discount_rate,

        -- Metadata
        current_timestamp as dbt_updated_at

    from daily_sales

)

select * from final
