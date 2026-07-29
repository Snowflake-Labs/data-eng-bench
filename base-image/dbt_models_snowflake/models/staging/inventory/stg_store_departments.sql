{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'STORE_DEPARTMENTS') }}

),

deduplicated AS (
    SELECT
        DEPARTMENT_ID,
        STORE_ID,
        DEPARTMENT_CODE,
        DEPARTMENT_NAME,
        FLOOR,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(DEPARTMENT_ID) AS department_id,
        TRIM(STORE_ID) AS store_id,
        TRIM(DEPARTMENT_CODE) AS department_code,
        TRIM(DEPARTMENT_NAME) AS department_name,
        TRIM(FLOOR) AS floor,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE DEPARTMENT_ID IS NOT NULL
)

SELECT * FROM renamed
