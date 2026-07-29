{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'GIFT_CARDS') }}

),

deduplicated AS (
    SELECT
        GIFT_CARD_ID,
        CARD_NUMBER,
        INITIAL_VALUE,
        CURRENT_BALANCE,
        CURRENCY_CODE,
        STATUS,
        PURCHASED_BY,
        ACTIVATED_AT,
        EXPIRES_AT,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY GIFT_CARD_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        GIFT_CARD_ID,
        CARD_NUMBER,
        INITIAL_VALUE,
        CURRENT_BALANCE,
        CURRENCY_CODE,
        STATUS,
        PURCHASED_BY,
        ACTIVATED_AT,
        EXPIRES_AT,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(GIFT_CARD_ID) AS gift_card_id,
        TRIM(CARD_NUMBER) AS card_number,
        INITIAL_VALUE AS initial_value,
        CURRENT_BALANCE AS current_balance,
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(STATUS) AS status,
        TRIM(PURCHASED_BY) AS purchased_by,
        ACTIVATED_AT AS activated_at,
        EXPIRES_AT AS expires_at,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE GIFT_CARD_ID IS NOT NULL
)

SELECT * FROM renamed
