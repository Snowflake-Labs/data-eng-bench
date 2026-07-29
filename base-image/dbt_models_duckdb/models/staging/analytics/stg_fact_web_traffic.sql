{{
    config(
        materialized='view',
        
        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'FACT_WEB_TRAFFIC') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(TRAFFIC_KEY) AS traffic_key,
        DATE_KEY AS date_key,
        COALESCE(TIME_KEY, 0) AS time_key,
        COALESCE(CUSTOMER_KEY, 0) AS customer_key,
        COALESCE(CHANNEL_KEY, 0) AS channel_key,
        TRIM(SESSION_ID) AS session_id,
        COALESCE(PAGE_VIEWS, 0) AS page_views,
        COALESCE(UNIQUE_PAGES, 0) AS unique_pages,
        COALESCE(SESSION_DURATION_SECONDS, 0) AS session_duration_seconds,
        BOUNCED AS bounced,
        CONVERTED AS converted,
        COALESCE(REVENUE, 0) AS revenue
    FROM cleaned
    WHERE SESSION_ID IS NOT NULL
)

SELECT * FROM renamed
