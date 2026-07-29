-- Warehouse Picking Efficiency Analysis
-- Analyzes order fulfillment speed and efficiency

with order_fulfillment as (
    select
        warehouse_name,
        order_date,
        fulfillment_date,
        count(distinct order_id) as orders_fulfilled,
        sum(quantity_ordered) as units_picked,
        date_diff('hour', min(order_date), max(fulfillment_date)) as total_hours
    from {{ ref('fct_sales') }}
    where fulfillment_date is not null
        and is_cancelled = false
    group by warehouse_name, order_date, fulfillment_date
),

efficiency_metrics as (
    select
        warehouse_name,
        date_trunc('week', order_date) as week_start,
        sum(orders_fulfilled) as weekly_orders,
        sum(units_picked) as weekly_units,
        round(avg(date_diff('hour', order_date, fulfillment_date)), 2) as avg_pick_time_hours,
        sum(case when date_diff('hour', order_date, fulfillment_date) <= 24 then 1 else 0 end) as same_day_picks,
        sum(case when date_diff('hour', order_date, fulfillment_date) <= 48 then 1 else 0 end) as two_day_picks
    from {{ ref('fct_sales') }}
    where fulfillment_date is not null
        and is_cancelled = false
    group by warehouse_name, date_trunc('week', order_date)
),

final as (
    select
        warehouse_name,
        week_start,
        weekly_orders,
        weekly_units,
        avg_pick_time_hours,
        same_day_picks,
        two_day_picks,
        round(100.0 * same_day_picks / weekly_orders, 2) as same_day_pick_pct,
        round(weekly_units::decimal / weekly_orders, 2) as units_per_order,
        case
            when avg_pick_time_hours <= 24 then 'Excellent'
            when avg_pick_time_hours <= 48 then 'Good'
            when avg_pick_time_hours <= 72 then 'Fair'
            else 'Needs Improvement'
        end as efficiency_rating
    from efficiency_metrics
)

select * from final
order by week_start desc, warehouse_name
