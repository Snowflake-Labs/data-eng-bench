{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'STORE_DEPARTMENTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
