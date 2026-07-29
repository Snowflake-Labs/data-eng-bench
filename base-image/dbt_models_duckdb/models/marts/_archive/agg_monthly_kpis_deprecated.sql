/*
================================================================================
DEPRECATED: Monthly KPI Aggregation
================================================================================
Replaced by: rpt_executive_kpis (2024-01-15)

This model is still referenced by:
- Legacy PowerBI dashboard (owner unknown)
- Some scheduled email report that goes to "execs@company.com"

We tried to deprecate this 3 times but each time someone complained.
At this point we're just letting it run until the heat death of the universe.

Cost: ~$8/day (does expensive window functions)
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['deprecated', 'powerbi_dependency', 'expensive'],
        meta={
            'owner': 'data-eng@company.com',
            'deprecation_date': '2024-01-15',
            'deprecation_attempts': 3,
            'estimated_daily_cost_usd': 8.00,
            'why_still_running': 'Unknown PowerBI consumer'
        }
    )
}}

-- Every time we try to turn this off, someone emails
-- "The numbers look wrong in the exec dashboard"
-- So we turn it back on and never investigate further

WITH monthly_sales AS (
    SELECT
        DATE_TRUNC('month', order_date) AS month_start,
        SUM(line_total) AS revenue,
        SUM(quantity_ordered) AS units,
        COUNT(DISTINCT order_id) AS orders,
        COUNT(DISTINCT customer_id) AS customers
    FROM {{ ref('fct_sales') }}
    GROUP BY 1
),

with_growth AS (
    SELECT
        month_start,
        revenue,
        units,
        orders,
        customers,

        -- Expensive window functions that probably aren't needed
        LAG(revenue, 1) OVER (ORDER BY month_start) AS prev_month_revenue,
        LAG(revenue, 12) OVER (ORDER BY month_start) AS same_month_ly_revenue,
        AVG(revenue) OVER (ORDER BY month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS trailing_12m_avg,
        SUM(revenue) OVER (ORDER BY month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS trailing_12m_total,

        -- More calculations that might not be used
        STDDEV(revenue) OVER (ORDER BY month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS trailing_12m_stddev,
        MIN(revenue) OVER (ORDER BY month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS trailing_12m_min,
        MAX(revenue) OVER (ORDER BY month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS trailing_12m_max

    FROM monthly_sales
)

SELECT
    month_start,
    revenue,
    units,
    orders,
    customers,
    revenue / NULLIF(orders, 0) AS aov,
    revenue / NULLIF(customers, 0) AS revenue_per_customer,

    prev_month_revenue,
    (revenue - prev_month_revenue) / NULLIF(prev_month_revenue, 0) AS mom_growth,

    same_month_ly_revenue,
    (revenue - same_month_ly_revenue) / NULLIF(same_month_ly_revenue, 0) AS yoy_growth,

    trailing_12m_avg,
    trailing_12m_total,
    trailing_12m_stddev,
    trailing_12m_min,
    trailing_12m_max,

    CURRENT_TIMESTAMP AS _generated_at
FROM with_growth
ORDER BY month_start DESC
