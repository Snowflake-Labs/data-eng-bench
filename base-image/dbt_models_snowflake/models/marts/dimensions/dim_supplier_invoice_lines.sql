{{
    config(
        materialized='table',
        tags=['dimension', 'lines', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_supplier_invoice_lines') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['invoice_line_id']) }} AS lines_key,
        invoice_line_id AS lines_id,

        -- Attributes
        invoice_id,
        po_line_id,
        description,
        quantity,
        unit_price,
        line_total,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE invoice_line_id IS NOT NULL
)

SELECT * FROM final
