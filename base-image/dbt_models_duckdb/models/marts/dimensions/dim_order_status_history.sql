{{
    config(
        materialized='table',
        tags=['dimension', 'history', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_order_status_history') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['history_id']) }} AS history_key,
        history_id AS history_id,
        
        -- Attributes
        order_id,
        old_status,
        new_status,
        changed_by,
        change_reason,
        notes,
        changed_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE history_id IS NOT NULL
)

SELECT * FROM final
