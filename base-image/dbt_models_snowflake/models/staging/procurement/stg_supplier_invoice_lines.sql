{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'SUPPLIER_INVOICE_LINES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY INVOICE_LINE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        INVOICE_LINE_ID,
        INVOICE_ID,
        PO_LINE_ID,
        DESCRIPTION,
        QUANTITY,
        UNIT_PRICE,
        LINE_TOTAL,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(INVOICE_LINE_ID) AS invoice_line_id,
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(PO_LINE_ID) AS po_line_id,
        TRIM(DESCRIPTION) AS description,
        COALESCE(QUANTITY, 0) AS quantity,
        COALESCE(UNIT_PRICE, 0) AS unit_price,
        COALESCE(LINE_TOTAL, 0) AS line_total,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE INVOICE_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
