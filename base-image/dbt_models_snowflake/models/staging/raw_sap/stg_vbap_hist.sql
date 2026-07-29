{{
    config(
        materialized='view',
        unique_key='variant_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'VBAP_HIST') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY VARIANT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

renamed AS (
    SELECT
        TRIM(ORDER_LINE_ID) AS order_line_id,
        TRIM(ORDER_ID) AS order_id,
        COALESCE(LINE_NUMBER, 0) as line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(SKU) AS sku,
        TRIM(PRODUCT_NAME) AS product_name,
        TRIM(VARIANT_NAME) AS variant_name,
        COALESCE(QUANTITY_ORDERED, 0) as quantity_ordered,
        COALESCE(QUANTITY_SHIPPED, 0) as quantity_shipped,
        COALESCE(QUANTITY_RETURNED, 0) as quantity_returned,
        TRIM(UNIT_PRICE) AS unit_price,
        TRIM(DISCOUNT_AMOUNT) AS discount_amount,
        TRIM(TAX_AMOUNT) AS tax_amount,
        TRIM(LINE_TOTAL) AS line_total,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system
    FROM deduplicated
    WHERE row_num = 1
      AND VARIANT_ID IS NOT NULL
)

SELECT * FROM renamed
