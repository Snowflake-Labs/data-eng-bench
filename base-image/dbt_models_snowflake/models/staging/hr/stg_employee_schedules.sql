{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'EMPLOYEE_SCHEDULES') }}

),

cleaned AS (
    SELECT
        SCHEDULE_ID,
        EMPLOYEE_ID,
        SCHEDULE_DATE,
        SHIFT_TYPE,
        START_TIME,
        END_TIME,
        LOCATION_ID,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SCHEDULE_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(SCHEDULE_ID) AS schedule_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        SCHEDULE_DATE AS schedule_date,
        TRIM(SHIFT_TYPE) AS shift_type,
        START_TIME AS start_time,
        END_TIME AS end_time,
        TRIM(LOCATION_ID) AS location_id,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE SCHEDULE_ID IS NOT NULL
)

SELECT * FROM renamed
