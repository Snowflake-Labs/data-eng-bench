{{
    config(
        materialized='view',
        tags=['intermediate', 'inventory', 'wms', 'supply_chain'],
        meta={
            'owner': 'supply-chain@company.com',
            'sla': '5:00am UTC',
            'estimated_runtime_minutes': 0.5,
            'snowflake_warehouse': 'TRANSFORM_XS',
            'data_source': 'Manhattan WMS',
            'row_count': 15,
            'slowly_changing': true
        }
    )
}}

/*
================================================================================
Intermediate model: int_inventory__warehouses_cleaned
Domain: inventory
Source: Manhattan WMS Warehouse Master
================================================================================

Warehouse reference data. Small, slowly-changing dimension (~15 warehouses).

WAREHOUSE NOTES:
- WH-001 through WH-005: US East region
- WH-006 through WH-010: US West region
- WH-011, WH-012: Canada
- WH-013, WH-014: UK/EU
- WH-007: Legacy system, has data quality issues (timestamps in wrong format)
- WH-012: New DC, not fully integrated yet (opened Q4 2024)

Code Review Comments (preserved for context):
- Supply Chain (2023-09-01): "WH-007 timestamps are weird"
- Marcus (2023-09-01): "Legacy WMS. Added TRY_CAST handling in staging."
- Jake (2024-10-01): "WH-012 showing 0 inventory"
- Sarah (2024-10-01): "New DC, WMS integration still in progress"
================================================================================
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_wms__warehouses') }}

),

cleaned AS (

    SELECT
        warehouse_id,
        warehouse_code,
        warehouse_name,
        warehouse_type,
        address_line_1,
        city,
        state_province,
        postal_code,
        country_code,
        latitude,
        longitude,
        timezone,
        phone,
        email,
        manager_name,
        square_footage,
        max_capacity_units,
        opened_date,
        priority,
        is_active,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
