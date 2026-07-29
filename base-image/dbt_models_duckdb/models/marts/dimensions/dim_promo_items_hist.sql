{{
    config(
        materialized='table',
        tags=['dimension', 'hist', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_promo_items_hist') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['mapping_id']) }} AS hist_key,
        mapping_id AS hist_id,
        
        -- Attributes
        promotion_id,
        product_id,
        category_id,
        brand_id,
        created_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE mapping_id IS NOT NULL
)

SELECT * FROM final
