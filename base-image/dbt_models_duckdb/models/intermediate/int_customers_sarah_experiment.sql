/*
================================================================================
EXPERIMENTAL: Customer Segmentation v2 - Sarah's Branch
================================================================================
Sarah was testing a new RFM segmentation approach.
The experiment was successful but this model was never cleaned up.

It now runs in production alongside the official model.
Both produce similar but slightly different results.
Nobody knows which one BI tools are actually using.
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['experimental', 'rfm', 'cleanup_needed'],
        meta={
            'owner': 'sarah.kim@company.com',
            'status': 'EXPERIMENTAL',
            'production_equivalent': 'int_customers__unified',
            'experiment_result': 'Successful but not productionized'
        }
    )
}}

-- Sarah's experimental RFM segmentation
-- Results were better than production but we never migrated

WITH customer_metrics AS (
    SELECT
        customer_id,
        COUNT(DISTINCT order_id) AS frequency,
        SUM(line_total) AS monetary,
        MAX(order_date) AS last_order_date,
        DATEDIFF('day', MAX(order_date), CURRENT_DATE) AS recency_days
    FROM {{ ref('fct_sales') }}
    GROUP BY customer_id
),

rfm_scores AS (
    SELECT
        customer_id,
        frequency,
        monetary,
        recency_days,

        -- RFM scoring (Sarah's improved methodology)
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY frequency) AS f_score,
        NTILE(5) OVER (ORDER BY monetary) AS m_score
    FROM customer_metrics
)

SELECT
    customer_id,
    frequency,
    monetary,
    recency_days,
    r_score,
    f_score,
    m_score,
    r_score * 100 + f_score * 10 + m_score AS rfm_combined,

    -- Sarah's improved segment names
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champion'
        WHEN r_score >= 4 AND f_score >= 3 THEN 'Loyal'
        WHEN r_score >= 4 THEN 'Recent'
        WHEN f_score >= 4 THEN 'Frequent'
        WHEN m_score >= 4 THEN 'Big Spender'
        WHEN r_score <= 2 AND f_score <= 2 THEN 'At Risk'
        WHEN r_score = 1 THEN 'Lost'
        ELSE 'Regular'
    END AS rfm_segment,

    'EXPERIMENTAL_V2' AS _model_version

FROM rfm_scores
