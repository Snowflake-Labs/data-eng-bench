{{
    config(
        materialized='view',
        
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'WEB_PAGE_VIEWS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PAGE_VIEW_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PAGE_VIEW_ID) AS page_view_id,
        TRIM(SESSION_ID) AS session_id,
        TRIM(PAGE_URL) AS page_url,
        TRIM(PAGE_TITLE) AS page_title,
        TRIM(PAGE_TYPE) AS page_type,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(CATEGORY_ID) AS category_id,
        VIEW_TIMESTAMP AS view_timestamp,
        COALESCE(TIME_ON_PAGE_SECONDS, 0) AS time_on_page_seconds,
        COALESCE(SCROLL_DEPTH_PERCENT, 0) AS scroll_depth_percent,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PAGE_VIEW_ID IS NOT NULL
)

SELECT * FROM renamed
