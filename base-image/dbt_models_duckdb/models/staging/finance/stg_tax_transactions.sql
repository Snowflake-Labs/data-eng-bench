{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'TAX_TRANSACTIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TAX_TRANSACTION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TAX_TRANSACTION_ID) AS tax_transaction_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(TAX_RATE_ID) AS tax_rate_id,
        COALESCE(TAXABLE_AMOUNT, 0) AS taxable_amount,
        COALESCE(TAX_AMOUNT, 0) AS tax_amount,
        TAX_DATE AS tax_date,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TAX_TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
