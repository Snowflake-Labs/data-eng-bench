-- Shipping Method Analysis
-- Analyzes shipping methods used

with shipments as (
    select * from {{ ref('stg_orders__shipments') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

shipping_methods as (
    select * from {{ ref('stg_reference__shipping_methods') }}
)

select
    sm.shipping_method_code,
    sm.shipping_method_name,
    sm.carrier_id,
    sm.estimated_days_min,
    sm.estimated_days_max,
    count(distinct s.shipment_id) as shipment_count,
    sum(s.shipping_cost) as total_shipping_cost,
    avg(s.shipping_cost) as avg_shipping_cost,
    avg(DATEDIFF(day, s.shipped_at, s.delivered_at)) as actual_avg_delivery_days
from shipping_methods sm
left join shipments s on sm.carrier_id = s.carrier_id
left join orders o on s.order_id = o.order_id
group by 1, 2, 3, 4, 5
