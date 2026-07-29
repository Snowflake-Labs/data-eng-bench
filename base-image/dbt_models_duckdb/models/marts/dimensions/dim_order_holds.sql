{{
    config(
        materialized='table',
        tags=['dimension', 'holds', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_order_holds') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['hold_id']) }} AS holds_key,
        hold_id AS holds_id,
        
        -- Attributes
        order_id,
        hold_type,
        hold_reason,
        hold_status,
        placed_by,
        placed_at,
        released_by,
        released_at,
        notes,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE hold_id IS NOT NULL
)

SELECT * FROM final
