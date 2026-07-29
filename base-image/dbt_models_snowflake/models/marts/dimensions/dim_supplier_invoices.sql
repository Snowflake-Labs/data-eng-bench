{{
    config(
        materialized='table',
        tags=['dimension', 'invoices', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_supplier_invoices') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['invoice_id']) }} AS invoices_key,
        invoice_id AS invoices_id,

        -- Attributes
        invoice_number,
        supplier_id,
        po_id,
        invoice_date,
        due_date,
        total_amount,
        currency_code,
        status,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE invoice_id IS NOT NULL
)

SELECT * FROM final
