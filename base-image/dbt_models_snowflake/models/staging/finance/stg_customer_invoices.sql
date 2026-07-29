{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CUSTOMER_INVOICES') }}

),

deduplicated AS (
    SELECT
        INVOICE_ID,
        INVOICE_NUMBER,
        ORDER_ID,
        CUSTOMER_ID,
        INVOICE_DATE,
        DUE_DATE,
        SUBTOTAL,
        TAX_AMOUNT,
        TOTAL_AMOUNT,
        AMOUNT_PAID,
        BALANCE_DUE,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY INVOICE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(INVOICE_NUMBER) AS invoice_number,
        TRIM(ORDER_ID) AS order_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        INVOICE_DATE AS invoice_date,
        DUE_DATE AS due_date,
        COALESCE(SUBTOTAL, 0) as subtotal,
        COALESCE(TAX_AMOUNT, 0) as tax_amount, TOTAL_AMOUNT as total_amount,
        COALESCE(AMOUNT_PAID, 0) as amount_paid,
        COALESCE(BALANCE_DUE, 0) as balance_due,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE INVOICE_ID IS NOT NULL
)

SELECT * FROM renamed
