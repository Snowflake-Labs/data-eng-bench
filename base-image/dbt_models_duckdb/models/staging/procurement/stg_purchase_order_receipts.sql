{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PURCHASE_ORDER_RECEIPTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY RECEIPT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RECEIPT_ID) AS receipt_id,
        TRIM(RECEIPT_NUMBER) AS receipt_number,
        TRIM(PO_ID) AS po_id,
        RECEIVED_AT AS received_at,
        TRIM(RECEIVED_BY) AS received_by,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RECEIPT_ID IS NOT NULL
)

SELECT * FROM renamed
