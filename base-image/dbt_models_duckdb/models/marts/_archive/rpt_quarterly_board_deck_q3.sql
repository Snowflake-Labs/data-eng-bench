/*
================================================================================
ONE-OFF: Q3 2024 Board Deck Report
================================================================================
Created: 2024-10-01 for Q3 board meeting
Intended lifespan: Until board meeting (2024-10-15)
Actual lifespan: Still running 3 months later

Every quarter we create these one-off board deck models.
Every quarter we forget to delete them.
We now have Q1, Q2, Q3, Q4 2024 all running simultaneously.
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['one_off', 'board_deck', 'q3_2024'],
        meta={
            'owner': 'data-eng@company.com',
            'created_for': 'Q3 2024 Board Meeting',
            'intended_delete_date': '2024-10-16',
            'actual_delete_date': 'Never'
        }
    )
}}

-- Q3 2024 specific board metrics
-- These were requested by the CEO for the board presentation
-- Format exactly matched the slide template

SELECT
    'Q3 2024' AS reporting_period,

    -- Revenue metrics
    SUM(CASE WHEN order_date BETWEEN '2024-07-01' AND '2024-09-30' THEN line_total ELSE 0 END) AS q3_revenue,
    SUM(CASE WHEN order_date BETWEEN '2024-04-01' AND '2024-06-30' THEN line_total ELSE 0 END) AS q2_revenue,
    SUM(CASE WHEN order_date BETWEEN '2024-07-01' AND '2024-09-30' THEN line_total ELSE 0 END) /
        NULLIF(SUM(CASE WHEN order_date BETWEEN '2024-04-01' AND '2024-06-30' THEN line_total ELSE 0 END), 0) - 1 AS qoq_growth,

    -- YoY comparison
    SUM(CASE WHEN order_date BETWEEN '2023-07-01' AND '2023-09-30' THEN line_total ELSE 0 END) AS q3_2023_revenue,
    SUM(CASE WHEN order_date BETWEEN '2024-07-01' AND '2024-09-30' THEN line_total ELSE 0 END) /
        NULLIF(SUM(CASE WHEN order_date BETWEEN '2023-07-01' AND '2023-09-30' THEN line_total ELSE 0 END), 0) - 1 AS yoy_growth,

    -- Customer metrics
    COUNT(DISTINCT CASE WHEN order_date BETWEEN '2024-07-01' AND '2024-09-30' THEN customer_id END) AS q3_active_customers,

    -- Board slide specific format
    TO_CHAR(SUM(CASE WHEN order_date BETWEEN '2024-07-01' AND '2024-09-30' THEN line_total ELSE 0 END), '$999,999,999') AS q3_revenue_formatted,

    CURRENT_TIMESTAMP AS _generated_at

FROM {{ ref('fct_sales') }}
