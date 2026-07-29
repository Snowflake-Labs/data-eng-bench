{{
    config(
        materialized='view',
        
        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'JOB_POSITIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY POSITION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(POSITION_ID) AS position_id,
        TRIM(POSITION_CODE) AS position_code,
        TRIM(POSITION_TITLE) AS position_title,
        TRIM(DEPARTMENT_ID) AS department_id,
        COALESCE(JOB_LEVEL, 0) AS job_level,
        COALESCE(MIN_SALARY, 0) AS min_salary,
        COALESCE(MAX_SALARY, 0) AS max_salary,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE POSITION_ID IS NOT NULL
)

SELECT * FROM renamed
