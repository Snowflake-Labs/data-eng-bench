{{
    config(
        materialized='view',

        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('orders', 'ORDER_LINES') }}

),

deduplicated AS (
    SELECT
        ORDER_LINE_ID,
        ORDER_ID,
        LINE_NUMBER,
        VARIANT_ID,
        PRODUCT_ID,
        SKU,
        PRODUCT_NAME,
        VARIANT_NAME,
        QUANTITY_ORDERED,
        QUANTITY_SHIPPED,
        QUANTITY_RETURNED,
        UNIT_PRICE,
        DISCOUNT_AMOUNT,
        TAX_AMOUNT,
        LINE_TOTAL,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY VARIANT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(ORDER_LINE_ID) AS order_line_id,
        TRIM(ORDER_ID) AS order_id, LINE_NUMBER as line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(SKU) AS sku,
        TRIM(PRODUCT_NAME) AS product_name,
        TRIM(VARIANT_NAME) AS variant_name, QUANTITY_ORDERED as quantity_ordered,
        COALESCE(QUANTITY_SHIPPED, 0) as quantity_shipped,
        COALESCE(QUANTITY_RETURNED, 0) as quantity_returned, UNIT_PRICE as unit_price,
        COALESCE(DISCOUNT_AMOUNT, 0) as discount_amount,
        COALESCE(TAX_AMOUNT, 0) as tax_amount, LINE_TOTAL as line_total,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE VARIANT_ID IS NOT NULL
)

SELECT * FROM renamed
