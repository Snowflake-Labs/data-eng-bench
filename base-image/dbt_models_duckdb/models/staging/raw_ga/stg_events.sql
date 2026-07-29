{{
    config(
        materialized='view',
        unique_key='event_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'EVENTS') }}
    
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
        TRIM(EVENT_TIMESTAMP) AS event_timestamp,
        TRIM(PAGE_URL) AS page_url,
        TRIM(ELEMENT_ID) AS element_id,
        TRIM(ELEMENT_CLASS) AS element_class,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(EVENT_VALUE) AS event_value,
        EVENT_DATA AS event_data,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE EVENT_ID IS NOT NULL
)

SELECT * FROM renamed
