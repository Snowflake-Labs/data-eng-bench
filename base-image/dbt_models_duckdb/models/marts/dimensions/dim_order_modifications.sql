{{
    config(
        materialized='table',
        tags=['dimension', 'modifications', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_order_modifications') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['modification_id']) }} AS modifications_key,
        modification_id AS modifications_id,
        
        -- Attributes
        order_id,
        modification_type,
        field_name,
        old_value,
        new_value,
        modified_by,
        modified_at,
        reason,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE modification_id IS NOT NULL
)

SELECT * FROM final
