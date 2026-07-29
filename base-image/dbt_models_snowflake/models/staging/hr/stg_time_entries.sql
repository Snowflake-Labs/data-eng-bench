{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'TIME_ENTRIES') }}

),

deduplicated AS (
    SELECT
        ENTRY_ID,
        EMPLOYEE_ID,
        ENTRY_DATE,
        CLOCK_IN,
        CLOCK_OUT,
        BREAK_MINUTES,
        HOURS_WORKED,
        ENTRY_TYPE,
        STATUS,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY ENTRY_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        ENTRY_ID,
        EMPLOYEE_ID,
        ENTRY_DATE,
        CLOCK_IN,
        CLOCK_OUT,
        BREAK_MINUTES,
        HOURS_WORKED,
        ENTRY_TYPE,
        STATUS,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ENTRY_ID) AS entry_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        ENTRY_DATE AS entry_date,
        CLOCK_IN AS clock_in,
        CLOCK_OUT AS clock_out,
        COALESCE(BREAK_MINUTES, 0) AS break_minutes,
        COALESCE(HOURS_WORKED, 0) AS hours_worked,
        TRIM(ENTRY_TYPE) AS entry_type,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ENTRY_ID IS NOT NULL
)

SELECT * FROM renamed
