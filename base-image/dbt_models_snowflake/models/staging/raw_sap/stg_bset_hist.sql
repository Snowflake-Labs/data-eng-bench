{{
    config(
        materialized='view',
        unique_key='tax_transaction_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'BSET_HIST') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TAX_TRANSACTION_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(TAX_TRANSACTION_ID) AS tax_transaction_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(INVOICE_ID) AS invoice_id,
        TRIM(TAX_RATE_ID) AS tax_rate_id,
        TRIM(TAXABLE_AMOUNT) AS taxable_amount,
        TRIM(TAX_AMOUNT) AS tax_amount,
        TAX_DATE AS tax_date,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        trim(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE TAX_TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
