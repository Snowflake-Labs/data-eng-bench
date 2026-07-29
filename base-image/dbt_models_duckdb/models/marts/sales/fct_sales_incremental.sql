/*
================================================================================
fct_sales_incremental - Production Incremental Sales Fact
================================================================================
This is the REAL production incremental model for sales data. It handles:
- Late-arriving data (up to 7 days)
- Deduplication with conflict resolution
- Merge logic for updates
- Historical corrections

INCIDENT HISTORY:
- 2024-01-15: P1 - Duplicate rows caused $2M revenue overstatement
  Root cause: Missing dedup logic for HomeStyle data
  Fix: Added ROW_NUMBER() dedup in CTE
  Ticket: INC-2024-0115

- 2024-03-22: P2 - Late-arriving data not captured
  Root cause: is_incremental() lookback was only 1 day
  Fix: Extended to 7 days
  Ticket: INC-2024-0322

- 2024-06-10: P1 - Model failed due to schema change in source
  Root cause: SAP added new column, broke SELECT *
  Fix: Explicit column list
  Ticket: INC-2024-0610

- 2024-09-05: P2 - Revenue mismatch vs finance system
  Root cause: Currency conversion timing
  Fix: Added exchange_rate snapshot logic
  Ticket: INC-2024-0905

Code Review Comments (preserved for context):
- Sarah (2024-01-10): "Why COALESCE instead of IFNULL?"
- Marcus (2024-01-10): "COALESCE is ANSI SQL, works across all warehouses"
- Sarah (2024-03-22): "7 day lookback seems excessive"
- Marcus (2024-03-22): "Finance insisted after the late-arriving data incident"
- Jake (2024-06-15): "Can we simplify the dedup logic?"
- Marcus (2024-06-15): "No, each CASE handles a specific edge case from prod"
================================================================================
*/

-- BLOCKED: int_sales__order_lines has missing columns (DATA-4522)
-- Blocked pending int_sales__order_lines schema update
{{
    config(
        enabled=false,
        materialized='incremental',
        unique_key='order_line_id',
        incremental_strategy='merge',
        merge_update_columns=['quantity_shipped', 'fulfillment_status', 'line_total', 'tax_amount', 'updated_at', 'dbt_updated_at'],
        on_schema_change='append_new_columns',
        cluster_by=['order_date', 'source_system'],
        tags=['incremental', 'production', 'sales', 'sla_critical'],
        meta={
            'owner': 'data-eng@company.com',
            'sla': '6am UTC',
            'estimated_runtime_minutes': 47,
            'snowflake_warehouse': 'TRANSFORM_XL',
            'incident_count': 4,
            'last_incident': '2024-09-05',
            'on_call_slack': '#data-oncall'
        }
    )
}}

/*
IMPORTANT: Do NOT simplify this model without understanding the edge cases.
Each piece of "complexity" exists because of a production incident.
See incident history above.
*/

-- Late-arriving data lookback window
-- Changed from 1 day to 7 days after INC-2024-0322
{% set lookback_days = 7 %}

WITH source_data AS (

    SELECT
        -- Explicit column list after INC-2024-0610 (schema change broke SELECT *)
        order_line_id,
        order_id,
        customer_id,
        product_id,
        sku,
        source_system,
        order_number,
        order_status,
        fulfillment_status,
        quantity_ordered,
        quantity_shipped,
        quantity_backordered,
        unit_price,
        extended_price,
        discount_amount,
        discount_percent,
        tax_amount,
        tax_rate,
        shipping_amount,
        line_total,
        currency_code,
        exchange_rate,
        order_date,
        shipped_date,
        delivered_date,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id

    FROM {{ ref('int_sales__order_lines') }}

    {% if is_incremental() %}
    WHERE
        -- Primary filter: recently updated records
        updated_at >= DATEADD('day', -{{ lookback_days }}, CURRENT_TIMESTAMP)

        -- Secondary filter: catch late-arriving historical corrections
        -- This was added after Finance found corrections weren't being picked up
        OR _loaded_at >= DATEADD('day', -{{ lookback_days }}, CURRENT_TIMESTAMP)

        -- Tertiary filter: reprocess any records that might have been affected
        -- by the currency conversion fix (INC-2024-0905)
        OR (
            order_date >= DATEADD('day', -{{ lookback_days }}, CURRENT_DATE)
            AND currency_code != 'USD'
        )
    {% endif %}

),

/*
Deduplication logic - DO NOT REMOVE OR SIMPLIFY
Added after INC-2024-0115 caused $2M revenue overstatement

Edge cases handled:
1. HomeStyle sends duplicate records with different timestamps
2. POS can send the same order twice if register reboots
3. B2B portal sometimes double-submits orders
4. SAP corrections come with same order_line_id but different _batch_id
*/
deduplicated AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_line_id
            ORDER BY
                -- Prefer most recent update
                updated_at DESC,
                -- If same update time, prefer non-cancelled status
                CASE WHEN order_status = 'CANCELLED' THEN 1 ELSE 0 END,
                -- If still tied, prefer record with shipping info
                CASE WHEN shipped_date IS NOT NULL THEN 0 ELSE 1 END,
                -- Final tiebreaker: latest batch
                _batch_id DESC
        ) AS _dedup_rank
    FROM source_data

),

-- Currency conversion snapshot (added after INC-2024-0905)
-- We now use the exchange rate at order time, not current rate
with_fx_snapshot AS (

    SELECT
        d.*,
        -- Store both original and USD-converted amounts
        CASE
            WHEN d.currency_code = 'USD' THEN d.line_total
            ELSE d.line_total * COALESCE(d.exchange_rate, fx.rate, 1.0)
        END AS line_total_usd,

        -- Flag records that used fallback exchange rate
        CASE
            WHEN d.currency_code = 'USD' THEN FALSE
            WHEN d.exchange_rate IS NOT NULL THEN FALSE
            WHEN fx.rate IS NOT NULL THEN FALSE
            ELSE TRUE  -- No rate found, used 1.0 fallback
        END AS _used_fallback_fx_rate

    FROM deduplicated d
    LEFT JOIN {{ ref('dim_exchange_rates') }} fx
        ON d.currency_code = fx.from_currency
        AND d.order_date = fx.rate_date
    WHERE d._dedup_rank = 1

),

-- Data quality flags (helps debugging without breaking pipeline)
with_dq_flags AS (

    SELECT
        *,

        -- Flag potential data quality issues
        CASE
            WHEN line_total < 0 AND order_status != 'RETURNED' THEN 'NEGATIVE_NON_RETURN'
            WHEN line_total > 100000 THEN 'HIGH_VALUE'
            WHEN quantity_ordered <= 0 THEN 'INVALID_QUANTITY'
            WHEN order_date > CURRENT_DATE THEN 'FUTURE_DATED'
            WHEN customer_id IS NULL AND source_system NOT IN ('B2B_GUEST', 'POS_ANONYMOUS') THEN 'MISSING_CUSTOMER'
            ELSE NULL
        END AS _dq_flag,

        -- Audit trail
        CURRENT_TIMESTAMP AS dbt_updated_at,
        '{{ invocation_id }}' AS _dbt_invocation_id

    FROM with_fx_snapshot

)

SELECT
    -- Primary key
    order_line_id,

    -- Foreign keys
    order_id,
    customer_id,
    product_id,

    -- Attributes
    sku,
    source_system,
    order_number,
    order_status,
    fulfillment_status,

    -- Quantities
    quantity_ordered,
    quantity_shipped,
    quantity_backordered,

    -- Financials (original currency)
    unit_price,
    extended_price,
    discount_amount,
    discount_percent,
    tax_amount,
    tax_rate,
    shipping_amount,
    line_total,
    currency_code,
    exchange_rate,

    -- Financials (USD converted)
    line_total_usd,

    -- Dates
    order_date,
    EXTRACT(YEAR FROM order_date) AS order_year,
    EXTRACT(MONTH FROM order_date) AS order_month,
    shipped_date,
    delivered_date,

    -- Timestamps
    created_at,
    updated_at,

    -- Metadata
    _loaded_at,
    _source_system,
    _batch_id,
    _dq_flag,
    _used_fallback_fx_rate,
    dbt_updated_at,
    _dbt_invocation_id

FROM with_dq_flags

-- Final safety check: exclude obviously bad records
-- These get logged separately for investigation
WHERE NOT (
    line_total IS NULL
    AND quantity_ordered IS NULL
)
