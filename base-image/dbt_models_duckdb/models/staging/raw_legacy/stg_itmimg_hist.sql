{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ITMIMG_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY IMAGE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
        COALESCE(SORT_ORDER, 0) AS sort_order,
        COALESCE(WIDTH, 0) AS width,
        COALESCE(HEIGHT, 0) AS height,
        COALESCE(FILE_SIZE_KB, 0) AS file_size_kb,
        IS_PRIMARY AS is_primary,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE IMAGE_ID IS NOT NULL
)

SELECT * FROM renamed
