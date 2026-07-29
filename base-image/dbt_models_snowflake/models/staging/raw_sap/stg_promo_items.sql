{{
    config(
        materialized='view',
        unique_key='mapping_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'PROMO_ITEMS') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MAPPING_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(MAPPING_ID) AS mapping_id,
        TRIM(PROMOTION_ID) AS promotion_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(CATEGORY_ID) AS category_id,
        TRIM(BRAND_ID) AS brand_id,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM deduplicated
    WHERE MAPPING_ID IS NOT NULL
)

SELECT * FROM renamed
