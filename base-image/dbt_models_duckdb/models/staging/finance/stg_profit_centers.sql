{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PROFIT_CENTERS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PROFIT_CENTER_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PROFIT_CENTER_ID) AS profit_center_id,
        TRIM(PROFIT_CENTER_CODE) AS profit_center_code,
        TRIM(PROFIT_CENTER_NAME) AS profit_center_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PROFIT_CENTER_ID IS NOT NULL
)

SELECT * FROM renamed
