/*
================================================================================
ABANDONED: ML Feature Engineering Model
================================================================================
Created: 2024-02-01
Purpose: Generate features for churn prediction model

Status: Data Science team pivot to different approach.
        This model is orphaned but "might be useful someday."

The ML project:
- Started: 2024-02-01
- Paused: 2024-04-15 (resource constraints)
- Resumed: 2024-05-01 (with different approach)
- This model: Forgotten

Cost: ~$6/day (generates 200+ features)
================================================================================
*/

-- Disabled: Abandoned ML feature model, uses Snowflake-specific functions
{{
    config(
        enabled=false,
        materialized='table',
        tags=['ml', 'abandoned', 'feature_engineering'],
        meta={
            'owner': 'data-science@company.com',
            'project': 'Customer Churn Prediction (v1 - abandoned)',
            'status': 'ABANDONED',
            'estimated_daily_cost_usd': 6.00,
            'features_generated': 200
        }
    )
}}

-- Data Science never uses this anymore
-- They switched to a real-time feature store
-- But we keep generating 200 features every night "just in case"

WITH customer_base AS (
    SELECT DISTINCT customer_id FROM {{ ref('dim_customers') }}
),

order_features AS (
    SELECT
        customer_id,

        -- Recency features
        DATEDIFF('day', MAX(order_date), CURRENT_DATE) AS days_since_last_order,
        DATEDIFF('day', MIN(order_date), CURRENT_DATE) AS customer_tenure_days,

        -- Frequency features
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT order_id)::FLOAT / NULLIF(DATEDIFF('month', MIN(order_date), CURRENT_DATE), 0) AS orders_per_month,

        -- Monetary features
        SUM(line_total) AS lifetime_value,
        AVG(line_total) AS avg_order_value,
        STDDEV(line_total) AS stddev_order_value,

        -- Trend features
        SUM(CASE WHEN order_date >= DATEADD('day', -30, CURRENT_DATE) THEN line_total ELSE 0 END) AS revenue_last_30d,
        SUM(CASE WHEN order_date >= DATEADD('day', -90, CURRENT_DATE) THEN line_total ELSE 0 END) AS revenue_last_90d,
        SUM(CASE WHEN order_date >= DATEADD('day', -365, CURRENT_DATE) THEN line_total ELSE 0 END) AS revenue_last_365d,

        -- Many more features that nobody uses...
        COUNT(DISTINCT DATE_TRUNC('month', order_date)) AS active_months,
        MAX(quantity_ordered) AS max_single_order_qty,
        MIN(line_total) AS min_order_value,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY line_total) AS median_order_value

    FROM {{ ref('fct_sales') }}
    GROUP BY customer_id
)

SELECT
    c.customer_id,
    COALESCE(o.days_since_last_order, 9999) AS days_since_last_order,
    COALESCE(o.customer_tenure_days, 0) AS customer_tenure_days,
    COALESCE(o.total_orders, 0) AS total_orders,
    COALESCE(o.orders_per_month, 0) AS orders_per_month,
    COALESCE(o.lifetime_value, 0) AS lifetime_value,
    COALESCE(o.avg_order_value, 0) AS avg_order_value,
    COALESCE(o.stddev_order_value, 0) AS stddev_order_value,
    COALESCE(o.revenue_last_30d, 0) AS revenue_last_30d,
    COALESCE(o.revenue_last_90d, 0) AS revenue_last_90d,
    COALESCE(o.revenue_last_365d, 0) AS revenue_last_365d,
    COALESCE(o.active_months, 0) AS active_months,

    -- Derived ratios (more features nobody uses)
    COALESCE(o.revenue_last_30d, 0) / NULLIF(o.revenue_last_90d, 0) AS revenue_30d_to_90d_ratio,
    COALESCE(o.revenue_last_90d, 0) / NULLIF(o.revenue_last_365d, 0) AS revenue_90d_to_365d_ratio,

    'ABANDONED_ML_V1' AS _model_version,
    CURRENT_TIMESTAMP AS _feature_generated_at

FROM customer_base c
LEFT JOIN order_features o ON c.customer_id = o.customer_id
