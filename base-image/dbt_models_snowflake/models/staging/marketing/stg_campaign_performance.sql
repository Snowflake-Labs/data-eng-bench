{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'CAMPAIGN_PERFORMANCE') }}

),

deduplicated AS (
    SELECT
        PERFORMANCE_ID,
        CAMPAIGN_ID,
        METRIC_DATE,
        IMPRESSIONS,
        CLICKS,
        CONVERSIONS,
        SPEND,
        REVENUE,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY PERFORMANCE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        PERFORMANCE_ID,
        CAMPAIGN_ID,
        METRIC_DATE,
        IMPRESSIONS,
        CLICKS,
        CONVERSIONS,
        SPEND,
        REVENUE,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PERFORMANCE_ID) AS performance_id,
        TRIM(CAMPAIGN_ID) AS campaign_id,
        METRIC_DATE AS metric_date,
        COALESCE(IMPRESSIONS, 0) AS impressions,
        COALESCE(CLICKS, 0) AS clicks,
        COALESCE(CONVERSIONS, 0) AS conversions,
        COALESCE(SPEND, 0) AS spend,
        COALESCE(REVENUE, 0) AS revenue,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PERFORMANCE_ID IS NOT NULL
)

SELECT * FROM renamed
