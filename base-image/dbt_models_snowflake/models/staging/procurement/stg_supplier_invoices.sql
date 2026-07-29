{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'SUPPLIER_INVOICES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY INVOICE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        INVOICE_ID,
        INVOICE_NUMBER,
        SUPPLIER_ID,
        PO_ID,
        INVOICE_DATE,
        DUE_DATE,
        TOTAL_AMOUNT,
        CURRENCY_CODE,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(INVOICE_NUMBER) AS invoice_number,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(PO_ID) AS po_id,
        INVOICE_DATE AS invoice_date,
        DUE_DATE AS due_date, TOTAL_AMOUNT as total_amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE INVOICE_ID IS NOT NULL
)

SELECT * FROM renamed
