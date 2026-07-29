{{
    config(
        materialized='table',
        tags=['dimension', 'transfers', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_inventory_transfers') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['transfer_id']) }} AS transfers_key,
        transfer_id AS transfers_id,
        
        -- Attributes
        transfer_number,
        transfer_type,
        source_type,
        source_warehouse_id,
        source_store_id,
        dest_type,
        dest_warehouse_id,
        dest_store_id,
        status,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE transfer_id IS NOT NULL
)

SELECT * FROM final
