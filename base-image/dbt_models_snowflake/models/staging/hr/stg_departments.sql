{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'DEPARTMENTS') }}

),

cleaned AS (
    SELECT
        DEPARTMENT_ID,
        DEPARTMENT_CODE,
        DEPARTMENT_NAME,
        PARENT_DEPARTMENT_ID,
        MANAGER_ID,
        IS_ACTIVE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(DEPARTMENT_ID) AS department_id,
        TRIM(DEPARTMENT_CODE) AS department_code,
        TRIM(DEPARTMENT_NAME) AS department_name,
        TRIM(PARENT_DEPARTMENT_ID) AS parent_department_id,
        TRIM(MANAGER_ID) AS manager_id,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE DEPARTMENT_ID IS NOT NULL
)

SELECT * FROM renamed
