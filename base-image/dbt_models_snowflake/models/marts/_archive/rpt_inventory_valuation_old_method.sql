/*
================================================================================
DEPRECATED: Inventory Valuation (Old FIFO Method)
================================================================================
Replaced: 2024-06-01 with weighted average method

Finance approved the switch but asked us to keep the old model running
"for comparison purposes" during the transition period.

The transition period was supposed to be 3 months.
It has been 7 months.
Finance stopped comparing 5 months ago.
Model still runs.
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['deprecated', 'fifo', 'finance_comparison'],
        meta={
            'owner': 'finance-analytics@company.com',
            'deprecation_date': '2024-06-01',
            'replacement': 'rpt_inventory_valuation',
            'transition_period': '3 months (actual: ongoing)',
            'estimated_daily_cost_usd': 4.50
        }
    )
}}

-- Old FIFO inventory valuation
-- Finance no longer needs this but we keep it running "just in case"

SELECT
    i.product_id,
    i.warehouse_id,
    i.quantity_on_hand,
    p.cost_price AS unit_cost,

    -- FIFO valuation (deprecated methodology)
    i.quantity_on_hand * p.cost_price AS inventory_value_fifo,

    -- This was how we calculated it before
    -- New method uses weighted average instead
    'FIFO_DEPRECATED' AS valuation_method,

    CURRENT_DATE AS valuation_date,
    CURRENT_TIMESTAMP AS _calculated_at

FROM {{ ref('fct_inventory_current') }} i
LEFT JOIN {{ ref('dim_products') }} p ON i.product_id = p.product_id
WHERE i.quantity_on_hand > 0
