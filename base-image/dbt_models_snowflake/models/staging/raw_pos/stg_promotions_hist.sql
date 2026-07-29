{{
    config(
        materialized='view',

        tags=['staging', 'raw_pos', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_pos', 'promotions_hist') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PROMOTION_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(PROMOTION_ID) AS promotion_id,
        TRIM(PROMOTION_CODE) AS promotion_code,
        TRIM(PROMOTION_NAME) AS promotion_name,
        TRIM(PROMOTION_TYPE) AS promotion_type,
        TRIM(DISCOUNT_TYPE) AS discount_type,
        TRIM(DISCOUNT_VALUE) AS discount_value,
        COALESCE(MIN_PURCHASE, 0) AS min_purchase,
        COALESCE(MAX_DISCOUNT, 0) AS max_discount,
        START_DATE AS start_date,
        END_DATE AS end_date,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE PROMOTION_ID IS NOT NULL
)

SELECT * FROM renamed
