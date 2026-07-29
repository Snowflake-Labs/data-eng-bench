{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'PURCHASE_ORDER_LINES') }}

),

deduplicated AS (
    SELECT
        PO_LINE_ID,
        PO_ID,
        LINE_NUMBER,
        VARIANT_ID,
        SKU,
        QUANTITY_ORDERED,
        QUANTITY_RECEIVED,
        UNIT_PRICE,
        LINE_TOTAL,
        created_at,
        ROW_NUMBER() OVER (PARTITION BY PO_LINE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        PO_LINE_ID,
        PO_ID,
        LINE_NUMBER,
        VARIANT_ID,
        SKU,
        QUANTITY_ORDERED,
        QUANTITY_RECEIVED,
        UNIT_PRICE,
        LINE_TOTAL,
        created_at
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PO_LINE_ID) AS po_line_id,
        TRIM(PO_ID) AS po_id, LINE_NUMBER as line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SKU) AS sku, QUANTITY_ORDERED as quantity_ordered,
        COALESCE(QUANTITY_RECEIVED, 0) as quantity_received, UNIT_PRICE as unit_price,
        COALESCE(LINE_TOTAL, 0) as line_total,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PO_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
