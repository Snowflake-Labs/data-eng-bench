{{
    config(
        materialized='view',
        tags=['intermediate', 'joins', 'sap', 'procurement'],
        meta={
            'owner': 'supply-chain@company.com',
            'sla': '5:30am UTC',
            'estimated_runtime_minutes': 3,
            'snowflake_warehouse': 'TRANSFORM_M',
            'sap_tables': ['EKKO', 'EKPO'],
            'sap_description': 'Purchase Order Header + Line Items',
            'domain': 'procurement'
        }
    )
}}

/*
================================================================================
Join model: int_ekko_ekpo_joined
Joins: stg_sap__ekko (PO Header) <-> stg_sap__ekpo (PO Line Items)
SAP Tables: EKKO + EKPO
================================================================================

Standard SAP Purchase Order join pattern.
EKKO = Purchase Order Header
EKPO = Purchase Order Item/Line

SAP NOTES:
- PO numbers are NOT globally unique (can repeat across company codes)
- Use po_id (our surrogate key) for joins, not po_number
- status field uses SAP status codes (see dim_po_status for mapping)
- currency_code is document currency, may differ from line item currencies

KNOWN ISSUES:
- Historical POs before 2020 may have missing ekpo records (migration gap)
- Some POs have 0 line items (cancelled before lines added)
- quantity_received can exceed quantity_ordered (over-delivery handling)

Code Review Comments (preserved for context):
- Marcus (2023-03-15): "Why LEFT JOIN? Shouldn't every PO have lines?"
- Sarah (2023-03-15): "Cancelled POs might not. Keep LEFT for safety."
- Procurement (2024-01-10): "quantity_received > quantity_ordered happens?"
- Sarah (2024-01-10): "Yes, for over-deliveries. SAP allows it."
- Marcus (2024-05-01): "t2_ prefix is terrible"
- Sarah (2024-05-01): "I KNOW. Technical debt. Add to backlog."
================================================================================
*/

WITH table1 AS (
    SELECT * FROM {{ ref('stg_sap__ekko') }}
),

table2 AS (
    SELECT * FROM {{ ref('stg_sap__ekpo') }}
),

joined AS (
    SELECT
        t1.po_id AS po_id,
        t1.po_number AS po_number,
        t1.supplier_id AS supplier_id,
        t1.warehouse_id AS warehouse_id,
        t1.status AS status,
        t1.total_amount AS total_amount,
        t1.currency_code AS currency_code,
        t1.expected_date AS expected_date,
        t2.po_line_id AS t2_po_line_id,
        t2.line_number as t2_line_number,
        t2.variant_id AS t2_variant_id,
        t2.sku as t2_sku,
        t2.quantity_ordered as t2_quantity_ordered,
        t2.quantity_received as t2_quantity_received,
        t2.unit_price as t2_unit_price
    FROM table1 t1
    LEFT JOIN table2 t2 ON t1.po_id = t2.po_id
)

SELECT * FROM joined
