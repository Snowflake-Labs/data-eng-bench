{{
    config(
        materialized='view',
        unique_key='coupon_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_ga', 'promo_codes_hist') }}

),

deduplicated AS (
    SELECT *,
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
        CREATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH,
        "_archived_at",
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
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE COUPON_ID IS NOT NULL
)

SELECT * FROM renamed
