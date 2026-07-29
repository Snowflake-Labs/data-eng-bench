-- Carrier Performance Analysis
-- Evaluates shipping carrier performance across key metrics

with carrier_shipments as (
    select
        carrier_name,
        count(*) as total_shipments,
        sum(shipping_cost) as total_cost,
        avg(shipping_cost) as avg_cost_per_shipment,
        avg(date_diff('day', ship_date, delivery_date)) as avg_transit_days,
        sum(case when delivery_date <= promised_delivery_date then 1 else 0 end) as on_time_deliveries,
        sum(case when delivery_date > promised_delivery_date then 1 else 0 end) as late_deliveries,
        sum(case when tracking_status = 'Damaged' then 1 else 0 end) as damaged_shipments,
        sum(weight_kg) as total_weight_shipped
    from {{ ref('stg_orders__shipments') }}
    where delivery_date is not null
    group by carrier_name
),

carrier_scores as (
    select
        carrier_name,
        total_shipments,
        round(total_cost, 2) as total_cost,
        round(avg_cost_per_shipment, 2) as avg_cost,
        round(avg_transit_days, 1) as avg_transit_days,
        on_time_deliveries,
        late_deliveries,
        damaged_shipments,
        round(total_weight_shipped, 2) as total_weight_kg,
        round(100.0 * on_time_deliveries / total_shipments, 2) as on_time_pct,
        round(100.0 * damaged_shipments / total_shipments, 2) as damage_rate_pct,
        -- Performance score (0-100)
        round(
            (100.0 * on_time_deliveries / total_shipments) * 0.6 +
            ((10 - least(avg_transit_days, 10)) / 10.0 * 100) * 0.3 +
            (100.0 * (1 - damaged_shipments::decimal / total_shipments)) * 0.1
        , 2) as overall_performance_score
    from carrier_shipments
),

final as (
    select
        *,
        case
            when overall_performance_score >= 90 then 'Excellent'
            when overall_performance_score >= 75 then 'Good'
            when overall_performance_score >= 60 then 'Fair'
            else 'Poor'
        end as performance_rating
    from carrier_scores
)

select * from final
order by overall_performance_score desc
