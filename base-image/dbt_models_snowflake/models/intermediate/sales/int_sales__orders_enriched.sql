{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

/*
================================================================================
 MODEL: int_sales__orders_enriched
 AUTHOR: Marcus Johnson
 CREATED: 2023-04-10
 LAST MODIFIED: 2024-10-15 by Sarah Chen

 DESCRIPTION:
 This intermediate model serves as the primary consolidation point for all
 order data across the organization's various transactional systems. It unions
 together order records from SAP ECC (legacy ERP), the new POS system, and
 performs critical data standardization operations.

 DATA SOURCES:
   - stg_sap__vbak: SAP Sales Document Header (VBAK table)
   - stg_pos__transactions: Point of Sale transaction records
   - (future) stg_shopify__orders: E-commerce orders (see TODO below)

 BUSINESS RULES:
   1. All monetary amounts are cast to decimal(18,2) for consistency
   2. Timestamps use TRY_CAST to handle malformed date strings from legacy systems
   3. Order status is preserved as-is from source (standardization in dim layer)

 GRAIN: One row per unique order_id

 PERFORMANCE METRICS:
   - Full refresh runtime: 2 min 15 sec
   - Incremental: N/A (view)
   - Downstream dependencies: fct_sales, fct_orders_master

 KNOWN ISSUES:
   - SAP exchange rates are point-in-time but we use current day rate
   - POS timestamps are in store local time, not UTC (BUG: DATA-1023)

 CHANGE LOG:
   2024-10-15: Added TRY_CAST for timestamp handling (Sarah)
   2024-07-22: Added exchange_rate column (Marcus)
   2024-03-01: Initial creation (Marcus)
================================================================================
*/

-- TODO: Add Shopify orders when e-commerce integration completes (Q1 2025)
-- TODO: Implement proper timezone conversion for POS orders
-- FIXME: Exchange rate should be order-date rate, not current rate

-- Helper macro-like approach to strip currency symbols
-- Data may contain "$108.53" or "945.9900 USD" formats
{% set clean_currency = "REGEXP_REPLACE(CAST(%s AS VARCHAR), '[^0-9.-]', '')::decimal(18,2)" %}

-- Helper to parse only YYYY-MM-DD timestamps (matches DuckDB TRY_CAST strictness)
{% set parse_timestamp = "CASE
    WHEN REGEXP_LIKE(CAST(%s AS VARCHAR), '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*')
    THEN TRY_CAST(%s AS TIMESTAMP)
    ELSE NULL
END" %}

with sap_orders as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        'SAP' as source_system,
        currency_code,
        exchange_rate,
        {{ clean_currency % 'subtotal' }} as subtotal,
        {{ clean_currency % 'discount_total' }} as discount_total,
        {{ clean_currency % 'shipping_total' }} as shipping_total,
        {{ clean_currency % 'tax_total' }} as tax_total,
        {{ clean_currency % 'grand_total' }} as grand_total,
        status,
        payment_status,
        fulfillment_status,
        {{ parse_timestamp % ('ordered_at', 'ordered_at') }} as ordered_at,
        {{ parse_timestamp % ('shipped_at', 'shipped_at') }} as shipped_at,
        {{ parse_timestamp % ('delivered_at', 'delivered_at') }} as delivered_at,
        {{ parse_timestamp % ('cancelled_at', 'cancelled_at') }} as cancelled_at
    from {{ ref('stg_sap__vbak') }}

),

pos_orders as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        'POS' as source_system,
        currency_code,
        exchange_rate,
        {{ clean_currency % 'subtotal' }} as subtotal,
        {{ clean_currency % 'discount_total' }} as discount_total,
        {{ clean_currency % 'shipping_total' }} as shipping_total,
        {{ clean_currency % 'tax_total' }} as tax_total,
        {{ clean_currency % 'grand_total' }} as grand_total,
        status,
        payment_status,
        fulfillment_status,
        {{ parse_timestamp % ('ordered_at', 'ordered_at') }} as ordered_at,
        {{ parse_timestamp % ('shipped_at', 'shipped_at') }} as shipped_at,
        {{ parse_timestamp % ('delivered_at', 'delivered_at') }} as delivered_at,
        {{ parse_timestamp % ('cancelled_at', 'cancelled_at') }} as cancelled_at
    from {{ ref('stg_pos__transactions') }}

),

all_orders as (

    select * from sap_orders
    union all
    select * from pos_orders

),

final as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        source_system,
        currency_code,
        exchange_rate,

        -- Order amounts
        subtotal,
        discount_total,
        shipping_total,
        tax_total,
        grand_total,

        -- Calculated fields
        (subtotal - discount_total) as net_subtotal,
        case
            when subtotal > 0 then (discount_total / subtotal)
            else 0
        end as discount_rate,

        -- Status fields
        status,
        payment_status,
        fulfillment_status,

        -- Timestamps
        ordered_at,
        shipped_at,
        delivered_at,
        cancelled_at,

        -- Derived flags
        case
            when cancelled_at is not null then true
            else false
        end as is_cancelled,

        case
            when delivered_at is not null then true
            else false
        end as is_delivered,

        -- Calculate fulfillment time in days
        case
            when delivered_at is not null and ordered_at is not null
            then DATEDIFF(day, ordered_at, delivered_at)
            else null
        end as days_to_fulfill

    from all_orders

)

select * from final
