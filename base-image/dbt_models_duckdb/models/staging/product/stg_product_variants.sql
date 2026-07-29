{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCT_VARIANTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY VARIANT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(SKU) AS sku,
        TRIM(VARIANT_NAME) AS variant_name,
        TRIM(VARIANT_DESCRIPTION) AS variant_description,
        TRIM(BARCODE) AS barcode,
        TRIM(BARCODE_TYPE) AS barcode_type,
        TRIM(GTIN) AS gtin,
        TRIM(MPN) AS mpn,
        COALESCE(WEIGHT, 0) AS weight,
        TRIM(WEIGHT_UOM) AS weight_uom,
        COALESCE(LENGTH, 0) AS length,
        COALESCE(WIDTH, 0) AS width,
        COALESCE(HEIGHT, 0) AS height,
        TRIM(DIMENSION_UOM) AS dimension_uom,
        COALESCE(COST_PRICE, 0) AS cost_price,
        COALESCE(COMPARE_AT_PRICE, 0) AS compare_at_price,
        REQUIRES_SHIPPING AS requires_shipping,
        IS_TAXABLE AS is_taxable,
        TRIM(INVENTORY_POLICY) AS inventory_policy
    FROM cleaned
    WHERE VARIANT_ID IS NOT NULL
)

SELECT * FROM renamed
