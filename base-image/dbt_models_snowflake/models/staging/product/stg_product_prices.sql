{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_PRICES') }}

),

deduplicated AS (
    SELECT
        PRICE_ID,
        VARIANT_ID,
        PRICE_TYPE,
        CURRENCY_CODE,
        PRICE_AMOUNT,
        COMPARE_AT_PRICE,
        COST_PRICE,
        MIN_QTY,
        MAX_QTY,
        CUSTOMER_TIER_ID,
        CHANNEL_ID,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        CREATED_BY
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PRICE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(PRICE_ID) AS price_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(PRICE_TYPE) AS price_type,
        TRIM(CURRENCY_CODE) AS currency_code,
        PRICE_AMOUNT AS price_amount,
        COALESCE(COMPARE_AT_PRICE, 0) AS compare_at_price,
        COALESCE(COST_PRICE, 0) AS cost_price,
        COALESCE(MIN_QTY, 0) AS min_qty,
        COALESCE(MAX_QTY, 0) AS max_qty,
        TRIM(CUSTOMER_TIER_ID) AS customer_tier_id,
        TRIM(CHANNEL_ID) AS channel_id,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        TRIM(CREATED_BY) AS created_by
    FROM deduplicated
    WHERE PRICE_ID IS NOT NULL
)

SELECT * FROM renamed
