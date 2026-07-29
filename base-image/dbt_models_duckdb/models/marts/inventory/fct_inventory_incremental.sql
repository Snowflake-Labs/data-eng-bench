/*
================================================================================
fct_inventory_incremental - Inventory Movements Fact (Incremental)
================================================================================
Tracks all inventory movements across warehouses incrementally.

This model was converted from full-refresh after it started taking 3+ hours.
The conversion was... eventful. See incident history.

INCIDENT HISTORY:
- 2024-02-01: Conversion from full-refresh to incremental
  Initial estimate: 1 week. Actual: 3 weeks.
  What went wrong: Everything.

- 2024-02-15: P1 - Inventory counts off by 15%
  Root cause: Incremental logic didn't handle reversals properly
  Fix: Added reversal_flag logic
  Duration: 6 hours
  Ticket: INC-2024-0215

- 2024-04-01: P2 - Warehouse 7 data missing
  Root cause: Warehouse 7 uses different timestamp format
  Fix: Added TRY_CAST with fallback
  Ticket: INC-2024-0401

- 2024-07-20: P1 - Negative inventory showing for 2000+ SKUs
  Root cause: Late-arriving "receive" records processed after "ship" records
  Fix: Added reprocessing window for quantity recalculation
  Duration: 14 hours (overnight)
  Ticket: INC-2024-0720

KNOWN LIMITATIONS:
- Warehouse 12 (new DC) not yet integrated
- International warehouses have 24-hour data lag
- Serial number tracking only works for electronics category

Code Review Comments:
- Marcus (2024-02-01): "This incremental logic looks complex"
- Sarah (2024-02-01): "Wait until you see the edge cases"
- Marcus (2024-04-01): "Why is warehouse 7 special?"
- Sarah (2024-04-01): "Legacy system. Don't ask."
- Jake (2024-07-21): "14 hour incident on a Saturday. Thanks."
- Sarah (2024-07-21): "Sorry. I owe you coffee. And therapy."
================================================================================
*/

-- Disabled: WMS movements schema changed, awaiting fix
{{
    config(
        enabled=false,
        materialized='incremental',
        unique_key='movement_id',
        incremental_strategy='merge',
        merge_update_columns=['quantity', 'status', 'updated_at', 'dbt_updated_at'],
        on_schema_change='sync_all_columns',
        partition_by={
            'field': 'movement_date',
            'data_type': 'date',
            'granularity': 'month'
        },
        cluster_by=['warehouse_id', 'product_id'],
        tags=['incremental', 'inventory', 'sla_critical'],
        meta={
            'owner': 'supply-chain@company.com',
            'sla': '7am UTC',
            'estimated_runtime_minutes': 23,
            'snowflake_warehouse': 'TRANSFORM_L',
            'incident_count': 3,
            'last_incident': '2024-07-20',
            'complexity_rating': 'HIGH',
            'requires_domain_knowledge': true
        }
    )
}}

{% set lookback_days = 3 %}
{% set reprocess_window_days = 7 %}  -- Added after INC-2024-0720

WITH source_movements AS (

    SELECT
        movement_id,
        warehouse_id,
        product_id,
        sku,
        lot_number,
        serial_number,
        movement_type,
        movement_reason,
        quantity,
        unit_of_measure,

        -- Warehouse 7 timestamp fix (INC-2024-0401)
        -- They send timestamps as strings in a weird format
        CASE
            WHEN warehouse_id = 'WH-007' THEN
                try_strptime(movement_timestamp, '%d/%m/%Y %H:%M:%S')
            ELSE
                try_strptime(movement_timestamp, '%Y-%m-%d %H:%M:%S')
        END AS movement_timestamp,

        DATE(movement_timestamp) AS movement_date,
        reference_type,
        reference_id,
        source_location,
        destination_location,
        status,
        created_by,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id

    FROM {{ ref('stg_wms__movements') }}

    {% if is_incremental() %}
    WHERE
        -- Standard incremental filter
        _loaded_at >= DATEADD('day', -{{ lookback_days }}, CURRENT_TIMESTAMP)

        -- Reprocess window for quantity recalculations (INC-2024-0720)
        -- Late-arriving receives need to be picked up
        OR (
            movement_type IN ('RECEIVE', 'RETURN', 'ADJUSTMENT')
            AND movement_date >= DATEADD('day', -{{ reprocess_window_days }}, CURRENT_DATE)
        )
    {% endif %}

),

-- Handle reversals (INC-2024-0215)
-- Some movements get reversed, we need to track both original and reversal
with_reversal_logic AS (

    SELECT
        sm.*,

        -- Flag if this is a reversal of another movement
        CASE
            WHEN sm.movement_reason LIKE '%REVERSAL%' THEN TRUE
            WHEN sm.movement_reason LIKE '%CORRECTION%' THEN TRUE
            WHEN sm.quantity < 0 AND sm.movement_type NOT IN ('SHIP', 'TRANSFER_OUT', 'SCRAP') THEN TRUE
            ELSE FALSE
        END AS is_reversal,

        -- Calculate net quantity impact
        CASE
            WHEN sm.movement_type IN ('RECEIVE', 'RETURN', 'TRANSFER_IN', 'ADJUSTMENT_IN') THEN ABS(sm.quantity)
            WHEN sm.movement_type IN ('SHIP', 'TRANSFER_OUT', 'SCRAP', 'ADJUSTMENT_OUT') THEN -1 * ABS(sm.quantity)
            WHEN sm.movement_type = 'ADJUSTMENT' THEN sm.quantity  -- Can be positive or negative
            ELSE 0
        END AS quantity_impact

    FROM source_movements sm

),

-- Deduplication (yes, WMS can send duplicates too)
deduplicated AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY movement_id
            ORDER BY
                updated_at DESC,
                _batch_id DESC
        ) AS _dedup_rank
    FROM with_reversal_logic

),

-- Add running totals for debugging (expensive but helpful)
with_running_totals AS (

    SELECT
        d.*,

        -- Running inventory balance per product/warehouse
        -- WARNING: This is expensive. Only calculate for recent data.
        {% if is_incremental() %}
        NULL AS running_balance  -- Skip for incremental runs
        {% else %}
        SUM(quantity_impact) OVER (
            PARTITION BY warehouse_id, product_id
            ORDER BY movement_timestamp, movement_id
            ROWS UNBOUNDED PRECEDING
        ) AS running_balance
        {% endif %}

    FROM deduplicated d
    WHERE _dedup_rank = 1

),

-- Final transformations
final AS (

    SELECT
        -- Primary key
        movement_id,

        -- Dimensions
        warehouse_id,
        product_id,
        sku,
        lot_number,
        serial_number,

        -- Movement details
        movement_type,
        movement_reason,
        quantity,
        quantity_impact,
        unit_of_measure,

        -- Timing
        movement_timestamp,
        movement_date,
        EXTRACT(YEAR FROM movement_date) AS movement_year,
        EXTRACT(MONTH FROM movement_date) AS movement_month,

        -- Reference
        reference_type,
        reference_id,
        source_location,
        destination_location,

        -- Status
        status,
        is_reversal,

        -- Running total (NULL for incremental)
        running_balance,

        -- Audit
        created_by,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,

        -- DQ flags
        CASE
            WHEN quantity = 0 THEN 'ZERO_QUANTITY'
            WHEN warehouse_id IS NULL THEN 'MISSING_WAREHOUSE'
            WHEN product_id IS NULL THEN 'MISSING_PRODUCT'
            WHEN movement_timestamp IS NULL THEN 'MISSING_TIMESTAMP'
            WHEN running_balance < 0 THEN 'NEGATIVE_INVENTORY'
            ELSE NULL
        END AS _dq_flag,

        -- Metadata
        CURRENT_TIMESTAMP AS dbt_updated_at,
        '{{ invocation_id }}' AS _dbt_invocation_id

    FROM with_running_totals

)

SELECT * FROM final
WHERE movement_id IS NOT NULL  -- Sanity check
