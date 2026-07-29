{{
    config(
        materialized='table',
        tags=['dimension', 'options', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_attribute_options') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['option_id']) }} AS options_key,
        option_id AS options_id,
        
        -- Attributes
        attribute_id,
        option_code,
        option_value,
        option_label,
        sort_order,
        swatch_type,
        swatch_value,
        is_default,
        is_active,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE option_id IS NOT NULL
)

SELECT * FROM final
