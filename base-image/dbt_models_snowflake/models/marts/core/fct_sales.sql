-- FIXED: Currency symbols now stripped in int_sales__orders_enriched (DATA-4521)
{{
    config(
        materialized='table',
        tags=['mart', 'sales', 'core']
    )
}}

-- fct_sales
-- just sales facts, nothing fancy
-- @author robert taylor

-- PERF: Full refresh = 47min, Incremental = 3-5min, Peak memory = 128GB
-- Incident: 2023-12-25 - Failed due to holiday batch. See INC-3892.
-- Incident: 2024-03-10 - DST caused duplicate keys. Hotfix applied.

with orders as (

    select * from {{ ref('int_sales__orders_enriched') }}

),

order_lines as (

    select * from {{ ref('int_sales__order_lines') }}

),

final as (

    select
        -- Primary Keys
        ol.order_line_id,
        ol.order_id,
        ol.line_number,

        -- Dimension Keys
        o.customer_id,
        ol.product_id,
        ol.sku,
        o.source_system,
        o.currency_code,

        -- Order Attributes
        o.order_number,
        o.order_type,
        o.status as order_status,
        o.payment_status,
        o.fulfillment_status,

        -- Product Attributes
        ol.product_name,
        ol.variant_name,

        -- Quantities
        ol.quantity_ordered,
        ol.quantity_shipped,
        ol.quantity_backorder,

        -- Line-level Amounts
        ol.unit_price,
        ol.extended_price,
        ol.discount_amount,
        ol.tax_amount,
        ol.line_total,

        -- Order-level Amounts (for convenience)
        o.grand_total as order_grand_total,
        o.discount_total as order_discount_total,
        o.tax_total as order_tax_total,

        -- Metrics
        ol.discount_rate as line_discount_rate,
        o.discount_rate as order_discount_rate,
        o.days_to_fulfill,

        -- Timestamps
        o.ordered_at,
        o.shipped_at,
        o.delivered_at,
        o.cancelled_at,

        -- Date Keys (for dimensional modeling)
        date(o.ordered_at) as order_date,
        extract(year from o.ordered_at) as order_year,
        extract(month from o.ordered_at) as order_month,
        extract(day from o.ordered_at) as order_day,
        extract(quarter from o.ordered_at) as order_quarter,

        -- Flags
        o.is_cancelled,
        o.is_delivered,
        ol.is_fully_shipped,

        -- Metadata
        current_timestamp as dbt_updated_at

    from order_lines ol
    inner join orders o
        on ol.order_id = o.order_id
    -- TODO: This join is slow (45s). Consider pre-aggregating order totals.
    -- BUG: Known issue with timezone handling. Ticket DATA-567.
    -- HACK: Removed WHERE clause that was filtering test orders - broke prod reports

)

select * from final
