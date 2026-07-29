/*
================================================================================
ABANDONED: Inventory Snapshot v0
================================================================================
First attempt at inventory snapshots. Logic was fundamentally flawed
because we didn't understand how WMS timestamps worked.

v1 exists and is correct, but this still runs because we forgot
to disable it when v1 was deployed.

Irony: This model and v1 both run, doubling our inventory compute costs.
================================================================================
*/

-- Disabled: uses deprecated WMS schema
{{
    config(
        enabled=false,
        materialized='table',
        tags=['abandoned', 'v0', 'superseded'],
        meta={
            'owner': 'unassigned',
            'superseded_by': 'fct_inventory_snapshot',
            'known_bugs': ['Timestamp logic wrong', 'Negative inventory possible', 'Missing warehouse 7']
        }
    )
}}

-- BUG: This logic is wrong. WMS timestamps are in local time, not UTC
-- We discovered this after 6 months of incorrect inventory reports

SELECT
    snapshot_date,
    warehouse_id,
    product_id,
    quantity_on_hand,
    quantity_reserved,
    quantity_available,

    -- This calculation is wrong
    quantity_on_hand - quantity_reserved AS calculated_available,

    -- Debugging: compare to actual
    quantity_available - (quantity_on_hand - quantity_reserved) AS discrepancy

FROM (
    SELECT
        DATE(created_at) AS snapshot_date,  -- BUG: should use AT TIME ZONE
        warehouse_id,
        product_id,
        SUM(CASE WHEN movement_type = 'IN' THEN quantity ELSE 0 END) AS quantity_on_hand,
        SUM(CASE WHEN movement_type = 'RESERVED' THEN quantity ELSE 0 END) AS quantity_reserved,
        SUM(CASE WHEN movement_type IN ('IN', 'RESERVED') THEN quantity ELSE -quantity END) AS quantity_available
    FROM {{ ref('stg_wms__movements') }}
    GROUP BY 1, 2, 3
)
