{{
    config(
        materialized='view',

        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('orders', 'ORDER_LINE_DISCOUNTS') }}

),

deduplicated AS (
    SELECT
        DISCOUNT_ID,
        ORDER_LINE_ID,
        DISCOUNT_TYPE,
        DISCOUNT_CODE,
        DISCOUNT_NAME,
        DISCOUNT_AMOUNT,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY DISCOUNT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(DISCOUNT_ID) AS discount_id,
        TRIM(ORDER_LINE_ID) AS order_line_id,
        TRIM(DISCOUNT_TYPE) AS discount_type,
        TRIM(DISCOUNT_CODE) AS discount_code,
        TRIM(DISCOUNT_NAME) AS discount_name,
        DISCOUNT_AMOUNT AS discount_amount,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE DISCOUNT_ID IS NOT NULL
)

SELECT * FROM renamed
