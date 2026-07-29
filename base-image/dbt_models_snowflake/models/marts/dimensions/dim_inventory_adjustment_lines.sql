{{
    config(
        materialized='table',
        tags=['dimension', 'lines', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_inventory_adjustment_lines') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['adjustment_line_id']) }} AS lines_key,
        adjustment_line_id AS lines_id,

        -- Attributes
        adjustment_id,
        line_number,
        variant_id,
        sku,
        quantity_before,
        quantity_adjustment,
        quantity_after,
        unit_cost,
        adjustment_value,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE adjustment_line_id IS NOT NULL
)

SELECT * FROM final
