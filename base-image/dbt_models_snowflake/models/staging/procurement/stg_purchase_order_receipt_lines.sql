{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'PURCHASE_ORDER_RECEIPT_LINES') }}

),

deduplicated AS (
    SELECT
        RECEIPT_LINE_ID,
        RECEIPT_ID,
        PO_LINE_ID,
        QUANTITY_RECEIVED,
        QUANTITY_ACCEPTED,
        QUANTITY_REJECTED,
        REJECT_REASON,
        created_at,
        ROW_NUMBER() OVER (PARTITION BY RECEIPT_LINE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        RECEIPT_LINE_ID,
        RECEIPT_ID,
        PO_LINE_ID,
        QUANTITY_RECEIVED,
        QUANTITY_ACCEPTED,
        QUANTITY_REJECTED,
        REJECT_REASON,
        created_at
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RECEIPT_LINE_ID) AS receipt_line_id,
        TRIM(RECEIPT_ID) AS receipt_id,
        TRIM(PO_LINE_ID) AS po_line_id,
        QUANTITY_RECEIVED AS quantity_received,
        COALESCE(QUANTITY_ACCEPTED, 0) AS quantity_accepted,
        COALESCE(QUANTITY_REJECTED, 0) AS quantity_rejected,
        TRIM(REJECT_REASON) AS reject_reason,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RECEIPT_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
