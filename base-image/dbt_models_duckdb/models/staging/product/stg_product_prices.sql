{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCT_PRICES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PRICE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PRICE_ID) AS price_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(PRICE_TYPE) AS price_type,
        TRIM(CURRENCY_CODE) AS currency_code,
        PRICE_AMOUNT AS price_amount,
        COALESCE(COMPARE_AT_PRICE, 0) AS compare_at_price,
        COALESCE(COST_PRICE, 0) AS cost_price,
        COALESCE(MIN_QTY, 0) AS min_qty,
        COALESCE(MAX_QTY, 0) AS max_qty,
        TRIM(CUSTOMER_TIER_ID) AS customer_tier_id,
        TRIM(CHANNEL_ID) AS channel_id,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        TRIM(CREATED_BY) AS created_by
    FROM cleaned
    WHERE PRICE_ID IS NOT NULL
)

SELECT * FROM renamed
