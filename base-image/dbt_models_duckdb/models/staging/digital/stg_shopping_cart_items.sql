{{
    config(
        materialized='view',
        
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SHOPPING_CART_ITEMS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CART_ITEM_ID ORDER BY updated_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CART_ITEM_ID) AS cart_item_id,
        TRIM(CART_ID) AS cart_id,
        TRIM(VARIANT_ID) AS variant_id,
        QUANTITY AS quantity,
        COALESCE(UNIT_PRICE, 0) AS unit_price,
        COALESCE(LINE_TOTAL, 0) AS line_total,
        ADDED_AT AS added_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CART_ITEM_ID IS NOT NULL
)

SELECT * FROM renamed
