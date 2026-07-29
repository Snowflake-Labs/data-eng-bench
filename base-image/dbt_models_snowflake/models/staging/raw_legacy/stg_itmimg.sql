{{
    config(
        materialized='view',

        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_legacy', 'itmimg') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY IMAGE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(IMAGE_ID) AS image_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(IMAGE_URL) AS image_url,
        TRIM(THUMBNAIL_URL) AS thumbnail_url,
        TRIM(ALT_TEXT) AS alt_text,
        TRIM(IMAGE_TYPE) AS image_type,
        COALESCE(SORT_ORDER, 0) as sort_order,
        COALESCE(WIDTH, 0) AS width,
        COALESCE(HEIGHT, 0) AS height,
        COALESCE(FILE_SIZE_KB, 0) as file_size_kb,
        IS_PRIMARY AS is_primary,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        trim(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM deduplicated
    WHERE IMAGE_ID IS NOT NULL
)

SELECT * FROM renamed
