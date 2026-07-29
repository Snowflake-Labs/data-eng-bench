{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'REVENUE_RECOGNITION') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY RECOGNITION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RECOGNITION_ID) AS recognition_id,
        TRIM(ORDER_ID) AS order_id,
        RECOGNITION_DATE AS recognition_date,
        AMOUNT AS amount,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RECOGNITION_ID IS NOT NULL
)

SELECT * FROM renamed
