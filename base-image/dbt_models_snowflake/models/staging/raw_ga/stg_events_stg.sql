{{
    config(
        materialized='view',
        unique_key='event_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_ga', 'events_stg') }}

),

deduplicated AS (
    SELECT
        EVENT_ID,
        SESSION_ID,
        EVENT_TYPE,
        EVENT_NAME,
        EVENT_TIMESTAMP,
        PAGE_URL,
        ELEMENT_ID,
        ELEMENT_CLASS,
        PRODUCT_ID,
        EVENT_VALUE,
        EVENT_DATA,
        CREATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH,
        TRIM("_status") AS _status
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EVENT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
        trim(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE EVENT_ID IS NOT NULL
)

SELECT * FROM renamed
