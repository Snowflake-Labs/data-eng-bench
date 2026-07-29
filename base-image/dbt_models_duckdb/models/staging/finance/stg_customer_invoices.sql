{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_INVOICES') }}
    
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
        TRIM(ORDER_ID) AS order_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        INVOICE_DATE AS invoice_date,
        DUE_DATE AS due_date,
        COALESCE(SUBTOTAL, 0) AS subtotal,
        COALESCE(TAX_AMOUNT, 0) AS tax_amount,
        TOTAL_AMOUNT AS total_amount,
        COALESCE(AMOUNT_PAID, 0) AS amount_paid,
        COALESCE(BALANCE_DUE, 0) AS balance_due,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE INVOICE_ID IS NOT NULL
)

SELECT * FROM renamed
