{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_pos', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'TRANS_LINES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY VARIANT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ORDER_LINE_ID) AS order_line_id,
        TRIM(ORDER_ID) AS order_id,
        COALESCE(LINE_NUMBER, 0) AS line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(SKU) AS sku,
        TRIM(PRODUCT_NAME) AS product_name,
        TRIM(VARIANT_NAME) AS variant_name,
        COALESCE(QUANTITY_ORDERED, 0) AS quantity_ordered,
        COALESCE(QUANTITY_SHIPPED, 0) AS quantity_shipped,
        COALESCE(QUANTITY_RETURNED, 0) AS quantity_returned,
        TRIM(UNIT_PRICE) AS unit_price,
        TRIM(DISCOUNT_AMOUNT) AS discount_amount,
        TRIM(TAX_AMOUNT) AS tax_amount,
        TRIM(LINE_TOTAL) AS line_total,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system
    FROM cleaned
    WHERE VARIANT_ID IS NOT NULL
)

SELECT * FROM renamed
