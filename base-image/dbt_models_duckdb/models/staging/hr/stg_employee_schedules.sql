{{
    config(
        materialized='view',
        
        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'EMPLOYEE_SCHEDULES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY SCHEDULE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
