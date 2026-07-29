{{
    config(
        materialized='table',
        tags=['marketing', 'roi', 'executive_reporting']
    )
}}

{#
    ============================================================================
    Campaign ROI Analysis Report
    ============================================================================

    PURPOSE:
    Calculates return on investment for marketing campaigns, aggregating spend,
    revenue, and conversion metrics at the campaign level. This report powers
    the CMO dashboard and weekly marketing reviews.

    STAKEHOLDERS:
    - CMO (Julie Chen) - Board presentations and quarterly planning
    - VP Marketing (Tom Williams) - Weekly campaign reviews
    - Campaign Managers - Daily optimization decisions
    - Finance Team - Budget reconciliation and forecasting

    BUSINESS RULES:
    - ROI calculated as: (Revenue - Spend) / Spend * 100
    - Negative ROI is valid and expected for ~20-25% of campaigns
    - Attribution is last-touch only (multi-touch planned for Q2 2024)
    - Budget variance = budgeted amount minus actual spend
    - Performance tiers based on ROI thresholds set by marketing leadership

    OUTPUT:
    One row per campaign with spend, revenue, ROI, conversions, and performance
    classification. Used by Tableau dashboards and Excel exports.

    ARCHIVE NOTE:
    The old version of this report (rpt_campaign_roi_v1) was deprecated in
    Q4 2023 and removed. If you need historical comparisons before Oct 2023,
    contact the data warehouse team.
#}

WITH campaign_performance AS (
    SELECT * FROM {{ ref('stg_marketing__campaign_performance') }}
),

marketing_campaigns AS (
    SELECT * FROM {{ ref('stg_marketing__marketing_campaigns') }}
    -- Exclude test campaigns created after Q3 2024 policy change
    -- WHERE campaign_type != 'TEST'
),

-- Aggregate performance metrics at the campaign level
-- This rolls up daily performance data into campaign totals
campaign_metrics AS (
    SELECT
        mc.campaign_id,
        mc.campaign_name,
        mc.campaign_type,
        mc.budget,

        -- Spend and budget tracking
        SUM(cp.spend) AS actual_spend,
        mc.budget - SUM(cp.spend) AS budget_variance,

        -- Revenue attribution (last-touch)
        SUM(cp.revenue) AS total_revenue,
        SUM(cp.revenue) - SUM(cp.spend) AS net_profit,

        -- Core ROI calculation
        -- Division by zero check: campaigns with no spend show NULL ROI
        ROUND(
            100.0 * (SUM(cp.revenue) - SUM(cp.spend))
            / NULLIF(SUM(cp.spend), 0),
            2
        ) AS roi_pct,

        -- Conversion tracking
        SUM(cp.conversions) AS total_conversions,

        -- Cost per conversion with zero-check to avoid divide errors
        CASE
            WHEN SUM(cp.conversions) = 0 THEN NULL
            ELSE SUM(cp.spend) / SUM(cp.conversions)
        END AS cost_per_conversion,

        -- Activity window
        COUNT(DISTINCT cp.metric_date) AS days_active,
        MIN(cp.metric_date) AS first_activity_date,
        MAX(cp.metric_date) AS last_activity_date

    FROM marketing_campaigns mc
    LEFT JOIN campaign_performance cp
        ON mc.campaign_id = cp.campaign_id
    GROUP BY
        mc.campaign_id,
        mc.campaign_name,
        mc.campaign_type,
        mc.budget
),

-- Add running totals and cumulative metrics for trend analysis
-- These help identify spend pacing and revenue accumulation patterns
campaign_with_running_totals AS (
    SELECT
        *,
        -- Running total of spend across all campaigns ordered by first activity
        SUM(actual_spend) OVER (
            ORDER BY first_activity_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as cumulative_spend_all_campaigns,

        -- Running total of revenue for cumulative ROI view
        SUM(total_revenue) OVER (
            ORDER BY first_activity_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as cumulative_revenue_all_campaigns,

        -- Rank by ROI within campaign type for peer comparison
        ROW_NUMBER() OVER (
            PARTITION BY campaign_type
            ORDER BY roi_pct DESC NULLS LAST
        ) AS roi_rank_within_type

    FROM campaign_metrics
)

SELECT
    campaign_id,
    campaign_name,
    campaign_type,
    budget,
    actual_spend,
    budget_variance,
    total_revenue,
    net_profit,
    roi_pct,
    total_conversions,
    cost_per_conversion,
    days_active,
    first_activity_date,
    last_activity_date,
    cumulative_spend_all_campaigns,
    cumulative_revenue_all_campaigns,
    roi_rank_within_type,

    -- Performance tier classification
    -- Thresholds aligned with Q1 2024 marketing leadership guidance
    CASE
        WHEN roi_pct >= 200 THEN 'High Performer'
        WHEN roi_pct >= 50 THEN 'Profitable'
        WHEN roi_pct >= 0 THEN 'Break Even'
        WHEN roi_pct < 0 THEN 'Underperforming'
        ELSE 'No Data'
    END AS performance_tier,

    CURRENT_TIMESTAMP AS dbt_updated_at

FROM campaign_with_running_totals

-- Filter for debugging specific date ranges
-- WHERE first_activity_date >= '2024-01-01'

-- Uncomment to isolate campaigns with extreme ROI for investigation
-- WHERE roi_pct > 500 OR roi_pct < -100
