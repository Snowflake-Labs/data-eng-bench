{{
    config(
        materialized='view',
        unique_key='transaction_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'BSEG_HIST') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(TRANSACTION_NUMBER) AS transaction_number,
        TRIM(ACCOUNT_ID) AS account_id,
        TRIM(PERIOD_ID) AS period_id,
        TRANSACTION_DATE AS transaction_date,
        TRIM(DEBIT_AMOUNT) AS debit_amount,
        TRIM(CREDIT_AMOUNT) AS credit_amount,
        TRIM(DESCRIPTION) AS description,
        TRIM(REFERENCE_TYPE) AS reference_type,
        TRIM(REFERENCE_ID) AS reference_id,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
