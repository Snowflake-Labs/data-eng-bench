{{
    config(
        materialized='view',

        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('analytics', 'DIM_EMPLOYEE') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        EMPLOYEE_KEY AS employee_key,
        TRIM(EMPLOYEE_ID) AS employee_id,
        TRIM(EMPLOYEE_NUMBER) AS employee_number,
        TRIM(EMPLOYEE_NAME) AS employee_name,
        TRIM(DEPARTMENT_NAME) AS department_name,
        TRIM(POSITION_TITLE) AS position_title,
        TRIM(MANAGER_NAME) AS manager_name,
        HIRE_DATE AS hire_date,
        IS_ACTIVE AS is_active
    FROM cleaned
    WHERE EMPLOYEE_ID IS NOT NULL
)

SELECT * FROM renamed
