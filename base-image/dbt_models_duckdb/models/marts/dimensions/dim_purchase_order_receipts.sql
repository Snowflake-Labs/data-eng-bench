{{
    config(
        materialized='table',
        tags=['dimension', 'receipts', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_purchase_order_receipts') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['receipt_id']) }} AS receipts_key,
        receipt_id AS receipts_id,
        
        -- Attributes
        receipt_number,
        po_id,
        received_at,
        received_by,
        status,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE receipt_id IS NOT NULL
)

SELECT * FROM final
