/*
================================================================================
TESTING MODEL - NOT FOR PRODUCTION USE
================================================================================
Author: Sarah Kim
Created: 2024-11-20
Purpose: Testing new deduplication logic before applying to int_orders

Status: TESTING (should not be in main branch)

Sarah: "I'll delete this after testing"
Narrator: She did not delete it after testing.
================================================================================
*/

{# Finally fixed! Sarah - 2025-01-12 #}
{# DISABLED: This should have been false from the start #}
{{
    config(
        materialized='view',
        enabled=false,
        tags=['testing', 'delete_after_review']
    )
}}

-- TESTING: New approach to handle late-arriving SAP data
-- If this works, apply to int_orders__vbak_cleaned

WITH raw_orders AS (
    SELECT * FROM {{ ref('stg_sap__vbak') }}
),

-- TEST: Dedup strategy #3
-- Previous strategies didn't handle the edge case where order_id
-- is duplicated with different customer_ids (data quality issue upstream)
dedup_attempt AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                updated_at DESC,
                CASE WHEN customer_id IS NOT NULL THEN 0 ELSE 1 END,
                _loaded_at DESC
        ) AS _dedup_rn
    FROM raw_orders
)

SELECT
    order_id,
    order_number,
    customer_id,
    order_type,
    order_source,
    channel_id,
    currency_code,
    exchange_rate,
    billing_address_id,
    shipping_address_id,
    subtotal,
    discount_total,
    shipping_total,
    tax_total,
    grand_total,
    status,
    payment_status,
    fulfillment_status,
    ordered_at,
    shipped_at,
    delivered_at,
    cancelled_at,
    ip_address,
    user_agent,
    notes,
    created_at,
    updated_at,
    _loaded_at,
    _source_system,
    _batch_id,

    -- Debugging columns for testing
    _dedup_rn,
    'TESTING_V3' AS _test_version

FROM dedup_attempt
WHERE _dedup_rn = 1
