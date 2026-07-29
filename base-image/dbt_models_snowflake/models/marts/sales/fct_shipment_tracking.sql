-- Shipment Tracking Status
-- Tracks shipment status updates
-- @author robert

-- perf: quick, ~500K events, 30 sec

-- TODO: Add carrier name (need to join to carrier dimension)
-- FIXME: Status values not standardized - UPS sends 'Delivered', FedEx sends 'DELIVERED'
-- BUG: Some tracking numbers duplicated across carriers. Added to DATA-1245.
-- HACK: Using row_number to get sequence but timestamps can be identical for batch updates

with shipment_tracking as (
    select * from {{ ref('stg_orders__shipment_tracking') }}
),

shipments as (
    select * from {{ ref('stg_orders__shipments') }}
)

select
    st.shipment_id,
    s.order_id,
    s.tracking_number,
    st.status,
    st.location,
    st.description,
    st.created_at as status_timestamp,
    row_number() over (partition by st.shipment_id order by st.created_at) as status_sequence
from shipment_tracking st
left join shipments s on st.shipment_id = s.shipment_id
