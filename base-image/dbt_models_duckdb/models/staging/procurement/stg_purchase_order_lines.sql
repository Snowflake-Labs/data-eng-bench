{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PURCHASE_ORDER_LINES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PO_LINE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PO_LINE_ID) AS po_line_id,
        TRIM(PO_ID) AS po_id,
        LINE_NUMBER AS line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SKU) AS sku,
        QUANTITY_ORDERED AS quantity_ordered,
        COALESCE(QUANTITY_RECEIVED, 0) AS quantity_received,
        UNIT_PRICE AS unit_price,
        COALESCE(LINE_TOTAL, 0) AS line_total,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PO_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
