{{
    config(
        materialized='view',
        
        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'FACT_MARKETING_SPEND') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(SPEND_KEY) AS spend_key,
        DATE_KEY AS date_key,
        TRIM(CAMPAIGN_ID) AS campaign_id,
        COALESCE(CHANNEL_KEY, 0) AS channel_key,
        COALESCE(IMPRESSIONS, 0) AS impressions,
        COALESCE(CLICKS, 0) AS clicks,
        COALESCE(CONVERSIONS, 0) AS conversions,
        COALESCE(SPEND_AMOUNT, 0) AS spend_amount,
        COALESCE(REVENUE_ATTRIBUTED, 0) AS revenue_attributed
    FROM cleaned
    WHERE CAMPAIGN_ID IS NOT NULL
)

SELECT * FROM renamed
