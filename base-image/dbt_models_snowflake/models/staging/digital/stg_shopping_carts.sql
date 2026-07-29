{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'SHOPPING_CARTS') }}

),

deduplicated AS (
    SELECT
        CART_ID,
        SESSION_ID,
        CUSTOMER_ID,
        CHANNEL_ID,
        STATUS,
        ITEM_COUNT,
        SUBTOTAL,
        CREATED_AT,
        UPDATED_AT,
        CONVERTED_AT,
        ORDER_ID
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CART_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(CART_ID) AS cart_id,
        TRIM(SESSION_ID) AS session_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(STATUS) AS status,
        COALESCE(ITEM_COUNT, 0) as item_count,
        COALESCE(SUBTOTAL, 0) as subtotal,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        CONVERTED_AT as converted_at,
        TRIM(ORDER_ID) AS order_id
    FROM cleaned
    WHERE CART_ID IS NOT NULL
)

SELECT * FROM renamed
