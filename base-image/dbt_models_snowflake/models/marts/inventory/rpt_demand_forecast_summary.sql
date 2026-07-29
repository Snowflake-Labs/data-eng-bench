-- Demand Forecast Summary
-- Summarizes demand forecasts

with demand_forecasts as (
    select * from {{ ref('stg_inventory__demand_forecasts') }}
),

warehouses as (
    select * from {{ ref('stg_inventory__warehouses') }}
)

select
    df.forecast_date,
    w.warehouse_name,
    count(distinct df.variant_id) as variants_forecasted,
    sum(df.forecasted_demand) as total_forecasted_demand,
    avg(df.confidence_level) as avg_confidence,
    sum(df.upper_bound) as total_upper_bound,
    sum(df.lower_bound) as total_lower_bound
from demand_forecasts df
left join warehouses w on df.warehouse_id = w.warehouse_id
group by 1, 2
order by 1, 2
