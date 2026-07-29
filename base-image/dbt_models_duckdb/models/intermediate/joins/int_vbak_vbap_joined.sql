{{
    config(
        materialized='view',
        tags=['intermediate', 'joins']
    )
}}

-- int_vbak_vbap_joined
-- SAP SD: Sales Document Header (VBAK) joined to Item (VBAP)
--
-- This is the core SAP sales order join. VBAK is the header, VBAP is the line item.
-- Standard SAP table structure - one header to many items.
--
-- SAP Table Reference:
--   VBAK - Sales Document: Header Data
--   VBAP - Sales Document: Item Data
--
-- Performance: View, depends on source size
-- Row count: ~10M lines (1.2M orders * ~8 items avg)
--
-- TODO: Add VBKD (business data) for payment terms
-- TODO: Add VBPA (partner) for ship-to address
-- FIXME: LEFT JOIN means orphaned VBAP records get NULL headers (data issue)
-- HACK: Column prefixes (t2_) are ugly but prevent name collision

WITH table1 AS (
    SELECT * FROM {{ ref('stg_sap__vbak') }}
),

table2 AS (
    SELECT * FROM {{ ref('stg_sap__vbap') }}
),

joined AS (
    SELECT
        t1.order_id AS order_id,
        t1.order_number AS order_number,
        t1.customer_id AS customer_id,
        t1.order_type AS order_type,
        t1.order_source AS order_source,
        t1.channel_id AS channel_id,
        t1.currency_code AS currency_code,
        t1.exchange_rate AS exchange_rate,
        t2.order_line_id AS t2_order_line_id,
        t2.line_number AS t2_line_number,
        t2.variant_id AS t2_variant_id,
        t2.product_id AS t2_product_id,
        t2.sku AS t2_sku,
        t2.product_name AS t2_product_name,
        t2.variant_name AS t2_variant_name
    FROM table1 t1
    LEFT JOIN table2 t2 ON t1.order_id = t2.order_id
)

SELECT * FROM joined
