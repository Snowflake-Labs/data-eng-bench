-- Late Shipments Analysis
-- Identifies patterns in late deliveries

with late_shipments as (
    select
        shipment_id,
        order_id,
        carrier_name,
        ship_date,
        delivery_date,
        promised_delivery_date,
        date_diff('day', promised_delivery_date, delivery_date) as days_late,
        warehouse_name,
        weight_kg,
        shipping_cost
    from {{ ref('stg_orders__shipments') }}
    where delivery_date > promised_delivery_date
),

late_shipment_analysis as (
    select
        carrier_name,
        warehouse_name,
        count(*) as late_shipment_count,
        round(avg(days_late), 1) as avg_days_late,
        max(days_late) as max_days_late,
        sum(shipping_cost) as cost_of_late_shipments,
        round(avg(weight_kg), 2) as avg_weight_kg
    from late_shipments
    group by carrier_name, warehouse_name
),

final as (
    select
        carrier_name,
        warehouse_name,
        late_shipment_count,
        avg_days_late,
        max_days_late,
        round(cost_of_late_shipments, 2) as cost_of_late_shipments,
        avg_weight_kg,
        case
            when avg_days_late > 7 then 'Critical Issue'
            when avg_days_late > 3 then 'Significant Delays'
            else 'Minor Delays'
        end as severity
    from late_shipment_analysis
)

select * from final
order by late_shipment_count desc
