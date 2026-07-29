{{
    config(
        materialized='view',
        unique_key='employee_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PA0002_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY EMPLOYEE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(EMPLOYEE_ID) AS employee_id,
        TRIM(EMPLOYEE_NUMBER) AS employee_number,
        TRIM(FIRST_NAME) AS first_name,
        TRIM(LAST_NAME) AS last_name,
        TRIM(EMAIL) AS email,
        TRIM(PHONE) AS phone,
        HIRE_DATE AS hire_date,
        TERMINATION_DATE AS termination_date,
        TRIM(MANAGER_ID) AS manager_id,
        TRIM(DEPARTMENT_ID) AS department_id,
        TRIM(POSITION_ID) AS position_id,
        TRIM(EMPLOYMENT_TYPE) AS employment_type,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE EMPLOYEE_ID IS NOT NULL
)

SELECT * FROM renamed
