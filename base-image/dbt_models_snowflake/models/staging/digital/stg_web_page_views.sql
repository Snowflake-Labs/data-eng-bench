{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'WEB_PAGE_VIEWS') }}

),

deduplicated AS (
    SELECT
        PAGE_VIEW_ID,
        SESSION_ID,
        PAGE_URL,
        PAGE_TITLE,
        PAGE_TYPE,
        PRODUCT_ID,
        CATEGORY_ID,
        VIEW_TIMESTAMP,
        TIME_ON_PAGE_SECONDS,
        SCROLL_DEPTH_PERCENT,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PAGE_VIEW_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
        COALESCE(TIME_ON_PAGE_SECONDS, 0) as time_on_page_seconds,
        COALESCE(SCROLL_DEPTH_PERCENT, 0) as scroll_depth_percent,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PAGE_VIEW_ID IS NOT NULL
)

SELECT * FROM renamed
