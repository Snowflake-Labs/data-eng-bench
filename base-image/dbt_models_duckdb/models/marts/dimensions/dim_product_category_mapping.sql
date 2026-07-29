{{
    config(
        materialized='table',
        tags=['dimension', 'mapping', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_category_mapping') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['mapping_id']) }} AS mapping_key,
        mapping_id AS mapping_id,
        
        -- Attributes
        product_id,
        category_id,
        is_primary,
        sort_order,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE mapping_id IS NOT NULL
)

SELECT * FROM final
