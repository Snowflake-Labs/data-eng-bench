/*
================================================================================
DEPRECATED: Customer LTV v1
================================================================================
STATUS: ORPHANED - Replaced by dim_customers.lifetime_value in Q2 2024
COST: ~$1.50/day in compute, runs nightly for no reason

This was our first attempt at LTV calculation. The methodology was flawed
(didn't account for refunds) but some legacy Looker dashboards still
reference this table.

Ticket: DATA-1892 - Migrate Looker dashboards and remove this model
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['deprecated', 'orphaned', 'looker_dependency'],
        meta={
            'owner': 'data-eng@company.com',
            'deprecation_date': '2024-04-01',
            'replacement': 'dim_customers.lifetime_value',
            'removal_blocked_by': 'Unknown Looker dashboards'
        }
    )
}}

-- WARNING: This LTV calculation is WRONG - does not account for refunds
-- See dim_customers for correct methodology

SELECT
    customer_id,
    SUM(line_total) AS lifetime_value,  -- BUG: includes refunded orders
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    COUNT(DISTINCT order_id) AS total_orders,
    DATEDIFF(day, MIN(order_date), MAX(order_date)) AS customer_lifespan_days,

    -- Flawed cohort assignment
    DATE_TRUNC('month', MIN(order_date)) AS acquisition_cohort,

    CURRENT_TIMESTAMP AS _calculated_at
FROM {{ ref('fct_sales') }}
GROUP BY customer_id
