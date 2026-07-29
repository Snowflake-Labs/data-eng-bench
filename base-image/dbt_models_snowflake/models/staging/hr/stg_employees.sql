{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'EMPLOYEES') }}

),

cleaned AS (
    SELECT
        EMPLOYEE_ID,
        EMPLOYEE_NUMBER,
        FIRST_NAME,
        LAST_NAME,
        EMAIL,
        PHONE,
        HIRE_DATE,
        TERMINATION_DATE,
        MANAGER_ID,
        DEPARTMENT_ID,
        POSITION_ID,
        EMPLOYMENT_TYPE,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMPLOYEE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
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
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE EMPLOYEE_ID IS NOT NULL
)

SELECT * FROM renamed
