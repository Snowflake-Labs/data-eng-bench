/*
================================================================================
fct_order_line_details - Order Line Item Details Fact
================================================================================
Detailed order line analysis with product variant information.

@author: robert.johnson@company.com
@created: 2023-02-15
@last_modified: 2024-10-22

Performance: ~2min runtime, ~3M rows
Warehouse: TRANSFORM_M recommended

KNOWN ISSUES:
- variant join is LEFT because ~2% of variants missing from PIM (DATA-2789)
- quantity_returned may not match stg_returns due to timing (DATA-2891)

TODO:
- [ ] Add shipping cost allocation per line (requested by Finance Q1 2025)
- [ ] Add bundle decomposition logic (blocked by PIM team)
- [ ] Performance optimization - consider incremental (DATA-3001)

Code Review Comments (preserved for context):
- Sarah (2023-02-15): "Why is variant_name coming from PV not products?"
- Robert (2023-02-15): "Variant-level names differ from product names for configurable items"
- Marcus (2024-03-10): "The FIXME has been here for a year..."
- Robert (2024-03-10): "Shopify team promised Q2. Now they say Q4."
- Finance (2024-10-22): "When can we get shipping cost per line?"
- Robert (2024-10-22): "Waiting on OMS data model changes, ETA unknown"
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['marts', 'sales', 'order_lines', 'finance_dependency'],
        meta={
            'owner': 'robert.johnson@company.com',
            'sla': '6:30am UTC',
            'estimated_runtime_minutes': 2,
            'estimated_row_count': 3000000,
            'snowflake_warehouse': 'TRANSFORM_M',
            'tableau_workbooks': ['Order Detail Explorer', 'Finance Line Item Report'],
            'looker_explores': ['order_lines'],
            'data_quality_issues': ['DATA-2789', 'DATA-2891'],
            'pending_enhancements': ['shipping_cost_allocation', 'bundle_decomposition']
        }
    )
}}

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    -- FIXME: Some variants missing from this source, need to check Shopify sync
    select * from {{ ref('stg_product__product_variants') }}
)

select
    ol.order_line_id,
    ol.order_id,
    o.order_number,
    o.customer_id,
    ol.variant_id,
    ol.product_id,
    ol.sku,
    pv.variant_name,
    ol.quantity_ordered,
    ol.quantity_shipped,
    ol.quantity_returned,
    ol.unit_price,
    ol.discount_amount,
    ol.tax_amount,
    ol.line_total,
    o.ordered_at
from order_lines ol
left join orders o on ol.order_id = o.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
