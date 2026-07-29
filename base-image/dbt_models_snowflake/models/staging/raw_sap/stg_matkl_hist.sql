{{
    config(
        materialized='view',
        unique_key='category_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'MATKL_HIST') }}

),

deduplicated AS (
    SELECT
        CATEGORY_ID,
        CATEGORY_CODE,
        CATEGORY_NAME,
        CATEGORY_DESCRIPTION,
        PARENT_CATEGORY_ID,
        CATEGORY_LEVEL,
        CATEGORY_PATH,
        CATEGORY_PATH_IDS,
        SORT_ORDER,
        IMAGE_URL,
        ICON_NAME,
        META_TITLE,
        META_DESCRIPTION,
        META_KEYWORDS,
        IS_FEATURED,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CATEGORY_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(CATEGORY_ID) AS category_id,
        TRIM(CATEGORY_CODE) AS category_code,
        TRIM(CATEGORY_NAME) AS category_name,
        TRIM(CATEGORY_DESCRIPTION) AS category_description,
        TRIM(PARENT_CATEGORY_ID) AS parent_category_id,
        COALESCE(CATEGORY_LEVEL, 0) AS category_level,
        TRIM(CATEGORY_PATH) AS category_path,
        TRIM(CATEGORY_PATH_IDS) AS category_path_ids,
        COALESCE(SORT_ORDER, 0) AS sort_order,
        TRIM(IMAGE_URL) AS image_url,
        TRIM(ICON_NAME) AS icon_name,
        TRIM(META_TITLE) AS meta_title,
        TRIM(META_DESCRIPTION) AS meta_description,
        TRIM(META_KEYWORDS) AS meta_keywords,
        IS_FEATURED AS is_featured,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system
    FROM cleaned
    WHERE CATEGORY_ID IS NOT NULL
)

SELECT * FROM renamed
