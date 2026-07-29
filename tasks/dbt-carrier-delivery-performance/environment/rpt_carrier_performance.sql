WITH shipment_metrics AS (
    SELECT
        carrier_id,
        COUNT(*) as total_shipments,
        COUNT(CASE WHEN status = 'DELIVERED' THEN 1 END) as delivered_shipments,
        COUNT(CASE WHEN status = 'IN_TRANSIT' THEN 1 END) as in_transit_shipments,
        COUNT(CASE WHEN status = 'CANCELLED' THEN 1 END) as cancelled_shipments,
        SUM(SHIPPING_COST) as total_shipping_cost,
        SUM(SHIPPING_COST) / COUNT(*) as avg_shipping_cost,
        SUM(WEIGHT) as total_weight,
        SUM(WEIGHT) / COUNT(*) as avg_weight,
        AVG(date_diff('day', SHIPPED_AT, DELIVERED_AT)) as avg_delivery_days,
        MIN(date_diff('day', SHIPPED_AT, DELIVERED_AT)) as min_delivery_days,
        MAX(date_diff('day', SHIPPED_AT, DELIVERED_AT)) as max_delivery_days,
        COUNT(CASE
            WHEN status = 'DELIVERED'
            AND date_diff('day', SHIPPED_AT, DELIVERED_AT) <= 7
            THEN 1
        END) as on_time_shipments
    FROM main.stg_orders__shipments
    WHERE carrier_id IS NOT NULL
        AND status != 'PENDING' 
    GROUP BY carrier_id
)

SELECT
    carrier_id,
    total_shipments,
    delivered_shipments,
    in_transit_shipments,
    cancelled_shipments,
    total_shipping_cost,
    avg_shipping_cost,
    total_weight,
    avg_weight,
    avg_delivery_days,
    min_delivery_days,
    max_delivery_days,
    on_time_shipments,
    on_time_shipments / delivered_shipments as on_time_delivery_rate,
    delivered_shipments / total_shipments as delivery_completion_rate 
FROM shipment_metrics
