{{
    config(
        materialized='view',

        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('orders', 'ORDER_PAYMENTS') }}

),

deduplicated AS (
    SELECT
        PAYMENT_ID,
        ORDER_ID,
        PAYMENT_METHOD_ID,
        PAYMENT_METHOD,
        AMOUNT,
        CURRENCY_CODE,
        STATUS,
        TRANSACTION_ID,
        AUTHORIZATION_CODE,
        CARD_LAST_FOUR,
        CARD_TYPE,
        PROCESSED_AT,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PAYMENT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(PAYMENT_ID) AS payment_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(PAYMENT_METHOD_ID) AS payment_method_id,
        TRIM(PAYMENT_METHOD) AS payment_method,
        AMOUNT AS amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(STATUS) AS status,
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(AUTHORIZATION_CODE) AS authorization_code,
        TRIM(CARD_LAST_FOUR) AS card_last_four,
        TRIM(CARD_TYPE) AS card_type,
        PROCESSED_AT AS processed_at,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE PAYMENT_ID IS NOT NULL
)

SELECT * FROM renamed
