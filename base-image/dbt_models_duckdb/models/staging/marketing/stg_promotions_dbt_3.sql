{{
    config(
        materialized='view',
        
        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PROMOTIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PROMOTION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PROMOTION_ID) AS promotion_id,
        TRIM(PROMOTION_CODE) AS promotion_code,
        TRIM(PROMOTION_NAME) AS promotion_name,
        TRIM(PROMOTION_TYPE) AS promotion_type,
        TRIM(DISCOUNT_TYPE) AS discount_type,
        -- Strip currency symbols ($, USD, etc.) before casting to DECIMAL (DISCOUNT_VALUE is VARCHAR)
        COALESCE(TRY_CAST(REGEXP_REPLACE(CAST(DISCOUNT_VALUE AS VARCHAR), '[^0-9.]', '', 'g') AS DECIMAL), 0.0) AS discount_value,
        -- MIN_PURCHASE and MAX_DISCOUNT are already DECIMAL, no need to strip currency symbols
        COALESCE(MIN_PURCHASE, 0.0) AS min_purchase,
        COALESCE(MAX_DISCOUNT, 0.0) AS max_discount,
        START_DATE AS start_date,
        END_DATE AS end_date,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PROMOTION_ID IS NOT NULL
)

SELECT * FROM renamed
