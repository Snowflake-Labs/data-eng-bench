{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_LINE_DISCOUNTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY DISCOUNT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(DISCOUNT_ID) AS discount_id,
        TRIM(ORDER_LINE_ID) AS order_line_id,
        TRIM(DISCOUNT_TYPE) AS discount_type,
        TRIM(DISCOUNT_CODE) AS discount_code,
        TRIM(DISCOUNT_NAME) AS discount_name,
        DISCOUNT_AMOUNT AS discount_amount,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE DISCOUNT_ID IS NOT NULL
)

SELECT * FROM renamed
