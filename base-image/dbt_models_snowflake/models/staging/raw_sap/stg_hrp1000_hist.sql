{{
    config(
        materialized='view',
        unique_key='assignment_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'HRP1000_HIST') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ASSIGNMENT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(ASSIGNMENT_ID) AS assignment_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        TRIM(POSITION_ID) AS position_id,
        START_DATE AS start_date,
        END_DATE AS end_date,
        IS_PRIMARY AS is_primary,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE ASSIGNMENT_ID IS NOT NULL
)

SELECT * FROM renamed
