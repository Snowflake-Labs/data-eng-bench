/*
================================================================================
ORPHANED MODEL - DO NOT USE
================================================================================
Created: 2023-06-15 during "that one incident" where fct_revenue was broken
Original purpose: Emergency backup for CFO dashboard

Nobody remembers to turn this off. It duplicates fct_revenue logic
and costs ~$5/day because it has an inefficient full table scan.

Owner: Unknown (created by contractor who left)
Ticket: DATA-2567 - Review and remove emergency backup models
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['orphaned', 'emergency_backup', 'remove_me'],
        meta={
            'owner': 'unassigned',
            'created_during': 'P1 Incident INC-2023-0615',
            'purpose': 'Emergency CFO dashboard backup',
            'estimated_daily_cost_usd': 5.00
        }
    )
}}

-- This is literally a copy of fct_revenue from 2023-06-15
-- with some hardcoded workarounds for that specific incident

SELECT
    order_date,
    currency_code,
    'COMBINED' AS source_system,  -- hardcoded workaround
    SUM(line_total) AS total_revenue,
    SUM(line_total - COALESCE(tax_amount, 0)) AS net_revenue,
    SUM(discount_amount) AS total_discounts,
    COUNT(DISTINCT order_id) AS total_orders,
    COUNT(DISTINCT customer_id) AS unique_customers,

    -- Metrics that were never actually used
    AVG(line_total) AS avg_line_value,
    STDDEV(line_total) AS stddev_line_value,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY line_total) AS median_line_value

FROM {{ ref('fct_sales') }}
WHERE order_date >= '2020-01-01'  -- arbitrary cutoff from the incident
GROUP BY order_date, currency_code
