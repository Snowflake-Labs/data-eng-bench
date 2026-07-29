{{
    config(
        materialized='table',
        tags=['dimension', 'rules', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_reorder_rules') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['rule_id']) }} AS rules_key,
        rule_id AS rules_id,

        -- Attributes
        variant_id,
        warehouse_id,
        min_quantity,
        max_quantity,
        reorder_point,
        reorder_quantity,
        lead_time_days,
        safety_stock,
        replenishment_method,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE rule_id IS NOT NULL
)

SELECT * FROM final
