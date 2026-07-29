{{
    config(
        materialized='view',

        tags=['staging', 'raw_pos', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_pos', 'coupons') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY COUPON_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE COUPON_ID IS NOT NULL
)

SELECT * FROM renamed
