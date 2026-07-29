{{
    config(
        materialized='view',
        unique_key='entry_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CATSDB') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ENTRY_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ENTRY_ID) AS entry_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        ENTRY_DATE AS entry_date,
        TRIM(CLOCK_IN) AS clock_in,
        TRIM(CLOCK_OUT) AS clock_out,
        COALESCE(BREAK_MINUTES, 0) AS break_minutes,
        COALESCE(HOURS_WORKED, 0) AS hours_worked,
        TRIM(ENTRY_TYPE) AS entry_type,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE ENTRY_ID IS NOT NULL
)

SELECT * FROM renamed
