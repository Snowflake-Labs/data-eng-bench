{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CUSTOMER_INVOICE_LINES') }}

),

deduplicated AS (
    SELECT
        INVOICE_LINE_ID,
        INVOICE_ID,
        ORDER_LINE_ID,
        DESCRIPTION,
        QUANTITY,
        UNIT_PRICE,
        LINE_TOTAL,
        TAX_AMOUNT,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY INVOICE_LINE_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(INVOICE_LINE_ID) AS invoice_line_id,
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(ORDER_LINE_ID) AS order_line_id,
        TRIM(DESCRIPTION) AS description,
        COALESCE(QUANTITY, 0) AS quantity,
        COALESCE(UNIT_PRICE, 0) AS unit_price,
        COALESCE(LINE_TOTAL, 0) AS line_total,
        COALESCE(TAX_AMOUNT, 0) AS tax_amount,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE INVOICE_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
