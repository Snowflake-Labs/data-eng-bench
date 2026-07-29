{{
    config(
        materialized='table',
        tags=['dimension', 'lines', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_inventory_transfer_lines') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['transfer_line_id']) }} AS lines_key,
        transfer_line_id AS lines_id,
        
        -- Attributes
        transfer_id,
        line_number,
        variant_id,
        sku,
        quantity_requested,
        quantity_shipped,
        quantity_received,
        quantity_variance,
        unit_cost,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE transfer_line_id IS NOT NULL
)

SELECT * FROM final
