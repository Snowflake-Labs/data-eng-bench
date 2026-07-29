{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'GL_TRANSACTIONS') }}

),

deduplicated AS (
    SELECT
        TRANSACTION_ID,
        TRANSACTION_NUMBER,
        ACCOUNT_ID,
        PERIOD_ID,
        TRANSACTION_DATE,
        DEBIT_AMOUNT,
        CREDIT_AMOUNT,
        DESCRIPTION,
        REFERENCE_TYPE,
        REFERENCE_ID,
        CREATED_BY,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        TRANSACTION_ID,
        TRANSACTION_NUMBER,
        ACCOUNT_ID,
        PERIOD_ID,
        TRANSACTION_DATE,
        DEBIT_AMOUNT,
        CREDIT_AMOUNT,
        DESCRIPTION,
        REFERENCE_TYPE,
        REFERENCE_ID,
        CREATED_BY,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(TRANSACTION_NUMBER) AS transaction_number,
        TRIM(ACCOUNT_ID) AS account_id,
        TRIM(PERIOD_ID) AS period_id,
        TRANSACTION_DATE AS transaction_date,
        COALESCE(DEBIT_AMOUNT, 0) AS debit_amount,
        COALESCE(CREDIT_AMOUNT, 0) AS credit_amount,
        TRIM(DESCRIPTION) AS description,
        TRIM(REFERENCE_TYPE) AS reference_type,
        TRIM(REFERENCE_ID) AS reference_id,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
