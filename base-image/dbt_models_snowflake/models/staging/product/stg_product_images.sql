{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_IMAGES') }}

),

deduplicated AS (
    SELECT
        IMAGE_ID,
        PRODUCT_ID,
        VARIANT_ID,
        IMAGE_URL,
        THUMBNAIL_URL,
        ALT_TEXT,
        IMAGE_TYPE,
        SORT_ORDER,
        WIDTH,
        HEIGHT,
        FILE_SIZE_KB,
        IS_PRIMARY,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
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
        COALESCE(FILE_SIZE_KB, 0) as file_size_kb, IS_PRIMARY as is_primary,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT as updated_at
    FROM deduplicated
    WHERE IMAGE_ID IS NOT NULL
)

SELECT * FROM renamed
