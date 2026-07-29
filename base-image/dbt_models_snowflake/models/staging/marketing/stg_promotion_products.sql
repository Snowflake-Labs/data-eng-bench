{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'PROMOTION_PRODUCTS') }}

),

deduplicated AS (
    SELECT
        MAPPING_ID,
        PROMOTION_ID,
        PRODUCT_ID,
        CATEGORY_ID,
        BRAND_ID,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY MAPPING_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        MAPPING_ID,
        PROMOTION_ID,
        PRODUCT_ID,
        CATEGORY_ID,
        BRAND_ID,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(MAPPING_ID) AS mapping_id,
        TRIM(PROMOTION_ID) AS promotion_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(CATEGORY_ID) AS category_id,
        TRIM(BRAND_ID) AS brand_id,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE MAPPING_ID IS NOT NULL
)

SELECT * FROM renamed
