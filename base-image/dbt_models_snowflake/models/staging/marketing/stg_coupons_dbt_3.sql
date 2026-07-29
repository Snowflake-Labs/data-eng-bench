{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_pos', 'coupons') }}

),

deduplicated AS (
    SELECT
        COUPON_ID,
        COUPON_CODE,
        PROMOTION_ID,
        USAGE_LIMIT,
        USAGE_COUNT,
        IS_ACTIVE,
        EXPIRES_AT,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY COUPON_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        COUPON_ID,
        COUPON_CODE,
        PROMOTION_ID,
        USAGE_LIMIT,
        USAGE_COUNT,
        IS_ACTIVE,
        EXPIRES_AT,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(COUPON_ID) AS coupon_id,
        TRIM(COUPON_CODE) AS coupon_code,
        TRIM(PROMOTION_ID) AS promotion_id,
        COALESCE(USAGE_LIMIT, 0) AS usage_limit,
        COALESCE(USAGE_COUNT, 0) AS usage_count,
        IS_ACTIVE AS is_active,
        EXPIRES_AT AS expires_at,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE COUPON_ID IS NOT NULL
)

SELECT * FROM renamed
