{{
    config(
        materialized='table',
        tags=['dimension', 'variants', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_variants') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['variant_id']) }} AS variants_key,
        variant_id AS variants_id,
        
        -- Attributes
        product_id,
        sku,
        variant_name,
        variant_description,
        barcode,
        barcode_type,
        gtin,
        mpn,
        weight,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE variant_id IS NOT NULL
)

SELECT * FROM final
