{{
    config(
        materialized='view',
        
        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'EMPLOYEE_POSITIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ASSIGNMENT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ASSIGNMENT_ID) AS assignment_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        TRIM(POSITION_ID) AS position_id,
        START_DATE AS start_date,
        END_DATE AS end_date,
        IS_PRIMARY AS is_primary,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ASSIGNMENT_ID IS NOT NULL
)

SELECT * FROM renamed
