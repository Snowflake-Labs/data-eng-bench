{{
    config(
        materialized='view',
        unique_key='note_id',
        tags=['staging', 'raw_sfdc', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_NOTES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY NOTE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(NOTE_ID) AS note_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(NOTE_TYPE) AS note_type,
        TRIM(NOTE_TEXT) AS note_text,
        IS_INTERNAL AS is_internal,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE NOTE_ID IS NOT NULL
)

SELECT * FROM renamed
