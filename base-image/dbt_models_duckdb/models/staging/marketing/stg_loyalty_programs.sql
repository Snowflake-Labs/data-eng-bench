{{
    config(
        materialized='view',
        
        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'LOYALTY_PROGRAMS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PROGRAM_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PROGRAM_ID) AS program_id,
        TRIM(PROGRAM_NAME) AS program_name,
        TRIM(PROGRAM_TYPE) AS program_type,
        COALESCE(POINTS_PER_DOLLAR, 0) AS points_per_dollar,
        COALESCE(POINTS_VALUE, 0) AS points_value,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PROGRAM_ID IS NOT NULL
)

SELECT * FROM renamed
