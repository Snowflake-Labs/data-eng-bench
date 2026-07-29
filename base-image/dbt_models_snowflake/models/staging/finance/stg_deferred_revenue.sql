{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'DEFERRED_REVENUE') }}

),

deduplicated AS (
    SELECT
        DEFERRED_ID,
        ORDER_ID,
        AMOUNT,
        RECOGNITION_START,
        RECOGNITION_END,
        RECOGNIZED_AMOUNT,
        REMAINING_AMOUNT,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY DEFERRED_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(DEFERRED_ID) AS deferred_id,
        TRIM(ORDER_ID) AS order_id,
        AMOUNT AS amount,
        RECOGNITION_START AS recognition_start,
        RECOGNITION_END AS recognition_end,
        COALESCE(RECOGNIZED_AMOUNT, 0) AS recognized_amount,
        COALESCE(REMAINING_AMOUNT, 0) AS remaining_amount,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE DEFERRED_ID IS NOT NULL
)

SELECT * FROM renamed
