{{
    config(
        materialized='view',
        
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'WEB_EVENTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY EVENT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(EVENT_ID) AS event_id,
        TRIM(SESSION_ID) AS session_id,
        TRIM(EVENT_TYPE) AS event_type,
        TRIM(EVENT_NAME) AS event_name,
        EVENT_TIMESTAMP AS event_timestamp,
        TRIM(PAGE_URL) AS page_url,
        TRIM(ELEMENT_ID) AS element_id,
        TRIM(ELEMENT_CLASS) AS element_class,
        TRIM(PRODUCT_ID) AS product_id,
        COALESCE(EVENT_VALUE, 0) AS event_value,
        EVENT_DATA AS event_data,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE EVENT_ID IS NOT NULL
)

SELECT * FROM renamed
