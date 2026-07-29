-- Shipment Line Details
-- Detailed shipment line items

with shipment_lines as (
    select * from {{ ref('stg_orders__shipment_lines') }}
),

shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    sl.shipment_line_id,
    sl.shipment_id,
    s.order_id,
    s.tracking_number,
    sl.order_line_id,
    ol.sku,
    ol.product_id,
    sl.quantity_shipped,
    ol.quantity_ordered,
    sl.quantity_shipped::float / nullif(ol.quantity_ordered, 0) as fulfillment_rate,
    s.shipped_at,
    s.delivered_at
from shipment_lines sl
left join shipments s on sl.shipment_id = s.shipment_id
left join order_lines ol on sl.order_line_id = ol.order_line_id
