{{
    config(
        materialized='table',
        tags=['dimension', 'lines', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_purchase_order_receipt_lines') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['receipt_line_id']) }} AS lines_key,
        receipt_line_id AS lines_id,

        -- Attributes
        receipt_id,
        po_line_id,
        quantity_received,
        quantity_accepted,
        quantity_rejected,
        reject_reason,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE receipt_line_id IS NOT NULL
)

SELECT * FROM final
