{{
    config(
        materialized='table',
        tags=['dimension', 'hist', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_mard_hist') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['inventory_id']) }} AS hist_key,
        inventory_id AS hist_id,
        
        -- Attributes
        variant_id,
        location_type,
        warehouse_id,
        store_id,
        location_id,
        quantity_on_hand,
        quantity_available,
        quantity_reserved,
        quantity_incoming,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE inventory_id IS NOT NULL
)

SELECT * FROM final
