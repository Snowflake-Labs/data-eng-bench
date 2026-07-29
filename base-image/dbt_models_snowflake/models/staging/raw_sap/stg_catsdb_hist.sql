{{
    config(
        materialized='view',
        unique_key='entry_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_sap', 'catsdb_hist') }}

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
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM source
    WHERE ENTRY_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ENTRY_ID ORDER BY created_at DESC NULLS LAST) = 1
)

SELECT * FROM renamed
