/*
================================================================================
TEMPORARY: Shopify Integration Testing
================================================================================
Created: 2024-08-01
Purpose: Testing new Shopify connector before go-live

Status: The Shopify project was cancelled. This model remains.

We kept it "just in case" the project gets revived.
The project has not been revived in 5 months.
================================================================================
*/

{{
    config(
        materialized='view',
        enabled=false,
        tags=['temporary', 'shopify', 'cancelled_project']
    )
}}

-- Shopify integration project was cancelled 2024-09-15
-- Keeping this model in case leadership changes their mind again

SELECT
    id AS order_id,
    order_number,
    email AS customer_email,
    created_at AS order_date,
    total_price,
    subtotal_price,
    total_tax,
    total_discounts,
    currency,
    financial_status,
    fulfillment_status,

    -- Mapping to our schema (incomplete because project was cancelled)
    'SHOPIFY' AS source_system,
    NULL AS customer_id,  -- TODO: implement customer matching
    NULL AS mapped_status,  -- TODO: status mapping

    CURRENT_TIMESTAMP AS _loaded_at

FROM {{ source('shopify', 'orders') }}
WHERE 1=0  -- returns no rows, but model still runs
