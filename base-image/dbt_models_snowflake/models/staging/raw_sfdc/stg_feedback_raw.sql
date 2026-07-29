{{
    config(
        materialized='view',
        unique_key='review_id',
        tags=['staging', 'raw_sfdc', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_sfdc', 'feedback') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY REVIEW_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(REVIEW_ID) AS review_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(ORDER_ID) AS order_id,
        COALESCE(RATING, 0) as rating,
        TRIM(REVIEW_TITLE) AS review_title,
        TRIM(REVIEW_TEXT) AS review_text,
        TRIM(PROS) AS pros,
        TRIM(CONS) AS cons,
        IS_VERIFIED_PURCHASE AS is_verified_purchase,
        IS_RECOMMENDED AS is_recommended,
        COALESCE(HELPFUL_COUNT, 0) as helpful_count,
        COALESCE(NOT_HELPFUL_COUNT, 0) as not_helpful_count,
        MEDIA_URLS AS media_urls,
        TRIM(STATUS) AS status,
        MODERATED_AT AS moderated_at,
        TRIM(MODERATED_BY) AS moderated_by,
        TRIM(REJECTION_REASON) AS rejection_reason,
        TRIM(REVIEW_SOURCE) AS review_source
    FROM cleaned
    WHERE REVIEW_ID IS NOT NULL
)

SELECT * FROM renamed
