/*
================================================================================
ALSO DO NOT USE - INCOMPLETE
================================================================================
This was Marcus's attempt to fix fct_sales_FINAL but he got pulled into
the SAP migration project and never finished.

Contains partial fixes for:
- HomeStyle duplicate key issue (partially fixed)
- Currency conversion bug (not fixed)
- Missing Canadian tax logic (added but untested)

Status: INCOMPLETE
Last touched: 2024-02-28
================================================================================
*/

{{
    config(
        materialized='table',
        enabled=false,
        tags=['incomplete', 'do_not_use', 'needs_review']
    )
}}

-- Marcus 2024-02-28: Started fixing the HomeStyle issue, need to finish
-- Marcus 2024-03-15: Still haven't gotten to this, Sarah is using USE_THIS_ONE
-- Marcus 2024-05-01: We really need to clean this up...

WITH base AS (
    SELECT * FROM {{ ref('int_sales__order_lines') }}
),

-- Attempted fix for HomeStyle duplicates
deduplicated AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, product_id, order_date
            ORDER BY dbt_updated_at DESC
        ) AS _rn
    FROM base
    WHERE source_system = 'SAP_HOMESTYLE'
    QUALIFY _rn = 1

    UNION ALL

    SELECT *, 1 AS _rn
    FROM base
    WHERE source_system != 'SAP_HOMESTYLE'
)

SELECT
    order_line_id,
    order_id,
    customer_id,
    product_id,
    sku,
    source_system,
    order_number,
    order_status,
    quantity_ordered,
    unit_price,
    extended_price,
    discount_amount,
    discount_percent,
    tax_amount,

    -- Canadian tax logic (UNTESTED)
    CASE
        WHEN currency_code = 'CAD' THEN tax_amount * 1.05  -- GST adjustment?
        ELSE tax_amount
    END AS tax_amount_adjusted,

    tax_rate,
    line_total,
    order_date,
    order_year,
    order_month,
    dbt_updated_at
FROM deduplicated
