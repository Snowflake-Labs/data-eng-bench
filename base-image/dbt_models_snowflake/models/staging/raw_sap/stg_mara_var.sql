{{
    config(
        materialized='view',
        unique_key='variant_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'MARA_VAR') }}

),

deduplicated AS (
    SELECT
        VARIANT_ID,
        PRODUCT_ID,
        SKU,
        VARIANT_NAME,
        VARIANT_DESCRIPTION,
        BARCODE,
        BARCODE_TYPE,
        GTIN,
        MPN,
        WEIGHT,
        WEIGHT_UOM,
        LENGTH,
        WIDTH,
        HEIGHT,
        DIMENSION_UOM,
        COST_PRICE,
        COMPARE_AT_PRICE,
        REQUIRES_SHIPPING,
        IS_TAXABLE,
        INVENTORY_POLICY,
        updated_at,
        created_at
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY VARIANT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
        COALESCE(WEIGHT, 0) as weight,
        TRIM(WEIGHT_UOM) AS weight_uom,
        COALESCE(LENGTH, 0) as length,
        COALESCE(WIDTH, 0) as width,
        COALESCE(HEIGHT, 0) as height,
        TRIM(DIMENSION_UOM) AS dimension_uom,
        trim(COST_PRICE) as cost_price,
        TRIM(COMPARE_AT_PRICE) AS compare_at_price,
        TRIM(REQUIRES_SHIPPING) AS requires_shipping,
        IS_TAXABLE AS is_taxable,
        TRIM(INVENTORY_POLICY) AS inventory_policy
    FROM cleaned
    WHERE VARIANT_ID IS NOT NULL
)

SELECT * FROM renamed
