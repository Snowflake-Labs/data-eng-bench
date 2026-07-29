{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'MARKETPLACE_LISTINGS') }}

),

deduplicated AS (
    SELECT
        LISTING_ID,
        CHANNEL_ID,
        PRODUCT_ID,
        VARIANT_ID,
        EXTERNAL_ID,
        LISTING_TITLE,
        LISTING_PRICE,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LISTING_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(LISTING_ID) AS listing_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(EXTERNAL_ID) AS external_id,
        TRIM(LISTING_TITLE) AS listing_title,
        COALESCE(LISTING_PRICE, 0) as listing_price,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE LISTING_ID IS NOT NULL
)

SELECT * FROM renamed
