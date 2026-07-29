{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'RETURN_REASONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY REASON_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(REASON_ID) AS reason_id,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(REASON_NAME) AS reason_name,
        TRIM(REASON_DESCRIPTION) AS reason_description,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE REASON_ID IS NOT NULL
)

SELECT * FROM renamed
