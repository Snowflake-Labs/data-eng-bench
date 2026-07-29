{{
    config(
        materialized='view',

        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_legacy', 'brands') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY BRAND_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(BRAND_ID) AS brand_id,
        TRIM(BRAND_CODE) AS brand_code,
        TRIM(BRAND_NAME) AS brand_name,
        TRIM(BRAND_DESCRIPTION) AS brand_description,
        TRIM(BRAND_LOGO_URL) AS brand_logo_url,
        TRIM(BRAND_WEBSITE) AS brand_website,
        TRIM(PARENT_BRAND_ID) AS parent_brand_id,
        IS_PRIVATE_LABEL AS is_private_label,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE BRAND_ID IS NOT NULL
)

SELECT * FROM renamed
