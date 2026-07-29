{{
    config(
        materialized='table',
        tags=['fact', 'procurement']
    )
}}

/*
================================================================================
fact_purchase_orders.sql

Procurement PO fact table. Used by supply chain and finance for:
- PO spend analysis
- Supplier performance tracking
- Lead time monitoring

Author: Supply Chain Analytics
Last modified: 2024-07-15

Performance: 5 min full refresh, ~200K POs
Dependencies: stg_procurement__purchase_orders, stg_procurement__suppliers

KNOWN ISSUES:
- actual_delivery_date always NULL - receiving integration not built yet
- Historical POs from SAP migration have incorrect timestamps
- Some supplier_ids orphaned (supplier was deleted in source)

TODO: Add PO line items for item-level analysis
TODO: Add actual_delivery_date from receiving module
FIXME: Currency conversion missing - all amounts in local currency
HACK: Using NULL for actual_delivery_date as placeholder
================================================================================
*/

with purchase_orders as (
    select
        po_id,
        po_number,
        supplier_id,
        warehouse_id,
        status,
        total_amount,
        currency_code,
        expected_date as expected_delivery_date,
        ordered_at as po_date,
        created_by,
        created_at,
        updated_at
    from {{ ref('stg_procurement__purchase_orders') }}
),

suppliers as (
    select
        supplier_id,
        supplier_name,
        supplier_type,
        payment_terms,
        lead_time_days,
        rating
    from {{ ref('stg_procurement__suppliers') }}
),

final as (
    select
        po.po_id,
        po.po_number,
        po.supplier_id,
        s.supplier_name,
        s.supplier_type,
        po.warehouse_id,
        po.po_date,
        po.expected_delivery_date,
        null as actual_delivery_date,
        po.total_amount,
        po.currency_code,
        po.status,
        s.payment_terms,
        s.lead_time_days,
        s.rating as supplier_rating,
        po.created_by,
        current_timestamp as dbt_updated_at
    from purchase_orders po
    left join suppliers s on po.supplier_id = s.supplier_id
)

select * from final
