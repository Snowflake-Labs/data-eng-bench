{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'JOB_POSITIONS') }}

),

deduplicated AS (
    SELECT
        POSITION_ID,
        POSITION_CODE,
        POSITION_TITLE,
        DEPARTMENT_ID,
        JOB_LEVEL,
        MIN_SALARY,
        MAX_SALARY,
        IS_ACTIVE,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY POSITION_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        POSITION_ID,
        POSITION_CODE,
        POSITION_TITLE,
        DEPARTMENT_ID,
        JOB_LEVEL,
        MIN_SALARY,
        MAX_SALARY,
        IS_ACTIVE,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
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
