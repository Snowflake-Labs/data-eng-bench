{{
    config(
        materialized='view',
        
        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'COST_CENTER_ASSIGNMENTS') }}
    
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
        TRIM(COST_CENTER_ID) AS cost_center_id,
        COALESCE(ALLOCATION_PERCENTAGE, 0) AS allocation_percentage,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ASSIGNMENT_ID IS NOT NULL
)

SELECT * FROM renamed
