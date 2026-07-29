{{
    config(
        materialized='table',
        tags=['dimension', 'hist', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_ship_methods_hist') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['shipping_method_id']) }} AS hist_key,
        shipping_method_id AS hist_id,
        
        -- Attributes
        shipping_method_code,
        shipping_method_name,
        carrier_id,
        estimated_days_min,
        estimated_days_max,
        is_express,
        is_active,
        created_at,
        updated_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE shipping_method_id IS NOT NULL
)

SELECT * FROM final
