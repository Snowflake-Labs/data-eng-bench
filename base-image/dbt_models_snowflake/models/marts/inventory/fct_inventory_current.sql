/*
================================================================================
fct_inventory_current - Current Inventory Snapshot
================================================================================
Provides the current inventory position across all warehouses and products.
This is a snapshot fact table that gets rebuilt daily.
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['inventory', 'snapshot']
    )
}}

SELECT
    INVENTORY_ID AS inventory_id,
    variant_id,
    warehouse_id,
    location_id,
    quantity_on_hand,
    quantity_available,
    quantity_reserved,
    quantity_incoming AS quantity_on_order,
    unit_cost,
    inventory_status,
    last_counted_at AS last_counted_date,
    CURRENT_DATE AS snapshot_date,
    CURRENT_TIMESTAMP AS dbt_updated_at
FROM {{ ref('stg_wms__inv_snapshot') }}
