{{
    config(
        materialized='table',
        tags=['dimension', 'centers', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_cost_centers') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['cost_center_id']) }} AS centers_key,
        cost_center_id AS centers_id,
        
        -- Attributes
        cost_center_code,
        cost_center_name,
        manager_id,
        is_active,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE cost_center_id IS NOT NULL
)

SELECT * FROM final
