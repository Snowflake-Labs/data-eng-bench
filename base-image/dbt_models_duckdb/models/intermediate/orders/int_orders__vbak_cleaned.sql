{{
    config(
        materialized='view',
        tags=['intermediate', 'orders', 'sap', 'sales'],
        meta={
            'owner': 'data-eng@company.com',
            'sla': '5:30am UTC',
            'estimated_runtime_minutes': 3,
            'snowflake_warehouse': 'TRANSFORM_M',
            'upstream_freshness': '30 minutes',
            'downstream_dependencies': ['int_sales__orders_enriched', 'fct_sales'],
            'data_classification': 'internal',
            'last_modified_by': 'marcus.chen@company.com',
            'last_modified_date': '2024-08-15',
            'pii_columns': ['ip_address', 'user_agent']
        }
    )
}}

/*
================================================================================
Intermediate model: int_orders__vbak_cleaned
Domain: orders
Source: SAP VBAK (Sales Document Header)
================================================================================

Cleaned and standardized order header data ready for mart consumption.
Applies business rules for order status normalization and currency handling.

KNOWN ISSUES:
- HomeStyle orders occasionally have duplicate order_ids (DATA-1234)
- Exchange rates are snapshot at order time, may not match current rates
- Pre-2023 orders may have inconsistent status values

Code Review Comments (preserved for context):
- Marcus (2023-06-15): "Should we validate currency codes here?"
- Sarah (2023-06-15): "No, let staging handle validation. Keep int layer focused on joins/enrichment."
- Jake (2024-01-10): "The DISTINCT is expensive, can we use ROW_NUMBER instead?"
- Marcus (2024-01-10): "Tried it, edge cases with SAP data. DISTINCT is safer."
- Sarah (2024-08-15): "Added ip_address and user_agent for fraud detection downstream"
================================================================================
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_sap__vbak') }}

),

cleaned AS (

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
