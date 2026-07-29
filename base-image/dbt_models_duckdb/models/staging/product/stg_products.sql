{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY BRAND_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(PRODUCT_CODE) AS product_code,
        TRIM(PRODUCT_NAME) AS product_name,
        TRIM(PRODUCT_DESCRIPTION) AS product_description,
        TRIM(SHORT_DESCRIPTION) AS short_description,
        TRIM(BRAND_ID) AS brand_id,
        TRIM(PRIMARY_CATEGORY_ID) AS primary_category_id,
        TRIM(PRODUCT_TYPE) AS product_type,
        TRIM(BASE_UOM) AS base_uom,
        COALESCE(WEIGHT, 0) AS weight,
        TRIM(WEIGHT_UOM) AS weight_uom,
        COALESCE(LENGTH, 0) AS length,
        COALESCE(WIDTH, 0) AS width,
        COALESCE(HEIGHT, 0) AS height,
        TRIM(DIMENSION_UOM) AS dimension_uom,
        IS_SERIALIZED AS is_serialized,
        IS_LOT_TRACKED AS is_lot_tracked,
        IS_PERISHABLE AS is_perishable,
        COALESCE(SHELF_LIFE_DAYS, 0) AS shelf_life_days,
        TRIM(COUNTRY_OF_ORIGIN) AS country_of_origin
    FROM cleaned
    WHERE BRAND_ID IS NOT NULL
)

SELECT * FROM renamed
