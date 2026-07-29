{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SUPPLIER_INVOICES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY INVOICE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(INVOICE_NUMBER) AS invoice_number,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(PO_ID) AS po_id,
        INVOICE_DATE AS invoice_date,
        DUE_DATE AS due_date,
        TOTAL_AMOUNT AS total_amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE INVOICE_ID IS NOT NULL
)

SELECT * FROM renamed
