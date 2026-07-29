{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'ORG_HIERARCHY') }}

),

deduplicated AS (
    SELECT
        HIERARCHY_ID,
        EMPLOYEE_ID,
        MANAGER_ID,
        LEVEL,
        PATH,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY HIERARCHY_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        HIERARCHY_ID,
        EMPLOYEE_ID,
        MANAGER_ID,
        LEVEL,
        PATH,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(HIERARCHY_ID) AS hierarchy_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        TRIM(MANAGER_ID) AS manager_id,
        COALESCE(LEVEL, 0) AS level,
        TRIM(PATH) AS path,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE HIERARCHY_ID IS NOT NULL
)

SELECT * FROM renamed
