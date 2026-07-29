/*
================================================================================
fct_purchase_orders - Purchase Order Fact
================================================================================
Purchase order transactions from SAP procurement module.
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['procurement', 'fact']
    )
}}

SELECT
    {{ dbt_utils.generate_surrogate_key(['h.po_number', 'l.line_number']) }} AS po_line_id,
    h.po_number,
    l.line_number AS po_line_number,
    h.supplier_id,
    l.variant_id,
    l.sku,
    l.quantity_ordered,
    l.quantity_received,
    l.unit_price,
    h.total_amount,
    h.currency_code,
    h.status AS po_status,
    h.ordered_at AS po_date,
    h.expected_date AS requested_date,
    h.created_by AS buyer_id,
    h.created_at,
    h.updated_at,
    CURRENT_TIMESTAMP AS dbt_updated_at
FROM {{ ref('stg_sap__ekko') }} h
LEFT JOIN {{ ref('stg_sap__ekpo') }} l ON h.PO_ID = l.po_id
