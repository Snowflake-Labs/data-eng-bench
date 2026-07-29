/*
================================================================================
STATUS: ORPHANED MODEL
================================================================================
WARNING: This model still runs in production, costing approximately $3/day
in Snowflake credits, but NO downstream consumers exist.

Last known usage: Q3 2023 by Finance team (now using rpt_sales_by_segment)
Ticket to remove: JIRA-DATA-2341 (low priority, backlogged since 2024-01)

Original author: james.wilson@company.com (no longer with company)
Created: 2022-08-15
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['orphaned', 'legacy', 'candidate_for_removal'],
        meta={
            'owner': 'unassigned',
            'status': 'ORPHANED',
            'estimated_daily_cost_usd': 3.00,
            'last_known_consumer': 'Finance Weekly Report (deprecated)',
            'removal_ticket': 'DATA-2341'
        }
    )
}}

-- NOTE: This model was used for a weekly finance report that was sunset in Q3 2023
-- We've kept it running because Marcus mentioned "someone might still need it"
-- but we've never confirmed who that might be.

-- TODO: Run lineage analysis to confirm no consumers (DATA-2341)

WITH sales AS (

    SELECT
        DATE_TRUNC(week, order_date) AS week_start,
        source_system,
        SUM(line_total) AS weekly_revenue,
        SUM(quantity_ordered) AS weekly_units,
        COUNT(DISTINCT order_id) AS weekly_orders,
        COUNT(DISTINCT customer_id) AS weekly_customers
    FROM {{ ref('fct_sales') }}
    WHERE order_date >= DATEADD(year, -2, CURRENT_DATE)  -- unnecessarily wide window
    GROUP BY 1, 2

)

SELECT
    week_start,
    source_system,
    weekly_revenue,
    weekly_units,
    weekly_orders,
    weekly_customers,
    -- Old calculation method retained for "consistency"
    weekly_revenue / NULLIF(weekly_orders, 0) AS avg_order_value,
    weekly_revenue / NULLIF(weekly_customers, 0) AS revenue_per_customer,

    -- These lag calculations run but output is never used
    LAG(weekly_revenue, 1) OVER (PARTITION BY source_system ORDER BY week_start) AS prev_week_revenue,
    LAG(weekly_revenue, 52) OVER (PARTITION BY source_system ORDER BY week_start) AS same_week_ly_revenue,

    CURRENT_TIMESTAMP AS _generated_at
FROM sales
ORDER BY week_start DESC
