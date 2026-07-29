{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_pos', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'TENDERS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PAYMENT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PAYMENT_ID) AS payment_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(PAYMENT_METHOD_ID) AS payment_method_id,
        TRIM(PAYMENT_METHOD) AS payment_method,
        TRIM(AMOUNT) AS amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(STATUS) AS status,
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(AUTHORIZATION_CODE) AS authorization_code,
        TRIM(CARD_LAST_FOUR) AS card_last_four,
        TRIM(CARD_TYPE) AS card_type,
        PROCESSED_AT AS processed_at,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE PAYMENT_ID IS NOT NULL
)

SELECT * FROM renamed
