{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'GIFT_CARD_TRANSACTIONS') }}

),

deduplicated AS (
    SELECT
        TRANSACTION_ID,
        GIFT_CARD_ID,
        TRANSACTION_TYPE,
        AMOUNT,
        BALANCE_AFTER,
        ORDER_ID,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        TRANSACTION_ID,
        GIFT_CARD_ID,
        TRANSACTION_TYPE,
        AMOUNT,
        BALANCE_AFTER,
        ORDER_ID,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(GIFT_CARD_ID) AS gift_card_id,
        TRIM(TRANSACTION_TYPE) AS transaction_type, AMOUNT as amount,
        COALESCE(BALANCE_AFTER, 0) as balance_after,
        TRIM(ORDER_ID) AS order_id,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
