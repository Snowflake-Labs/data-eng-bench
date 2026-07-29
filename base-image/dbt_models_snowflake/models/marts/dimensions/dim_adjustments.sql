{{
    config(
        materialized='table',
        tags=['dimension', 'adjustments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_adjustments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['adjustment_id']) }} AS adjustments_key,
        adjustment_id AS adjustments_id,

        -- Attributes
        adjustment_number,
        warehouse_id,
        adjustment_type,
        status,
        total_lines,
        total_quantity,
        total_value,
        reason_code,
        notes,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE adjustment_id IS NOT NULL
)

SELECT * FROM final
