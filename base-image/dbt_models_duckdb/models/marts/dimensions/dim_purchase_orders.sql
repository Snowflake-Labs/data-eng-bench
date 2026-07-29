{{
    config(
        materialized='table',
        tags=['dimension', 'orders', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_purchase_orders') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['po_id']) }} AS orders_key,
        po_id AS orders_id,
        
        -- Attributes
        po_number,
        supplier_id,
        warehouse_id,
        status,
        total_amount,
        currency_code,
        expected_date,
        ordered_at,
        created_by,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE po_id IS NOT NULL
)

SELECT * FROM final
