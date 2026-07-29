{{
    config(
        materialized='table',
        tags=['dimension', 'products', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_promotion_products') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['mapping_id']) }} AS products_key,
        mapping_id AS products_id,
        
        -- Attributes
        promotion_id,
        product_id,
        category_id,
        brand_id,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE mapping_id IS NOT NULL
)

SELECT * FROM final
