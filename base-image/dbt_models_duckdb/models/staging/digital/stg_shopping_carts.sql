{{
    config(
        materialized='view',
        
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SHOPPING_CARTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CART_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CART_ID) AS cart_id,
        TRIM(SESSION_ID) AS session_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(STATUS) AS status,
        COALESCE(ITEM_COUNT, 0) AS item_count,
        COALESCE(SUBTOTAL, 0) AS subtotal,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        CONVERTED_AT AS converted_at,
        TRIM(ORDER_ID) AS order_id
    FROM cleaned
    WHERE CART_ID IS NOT NULL
)

SELECT * FROM renamed
