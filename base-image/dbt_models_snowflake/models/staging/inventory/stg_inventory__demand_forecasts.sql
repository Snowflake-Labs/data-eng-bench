{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.DEMAND_FORECASTS

with source as (
    select * from {{ source('inventory', 'DEMAND_FORECASTS') }}
),

renamed as (
    select
        trim(forecast_id) as forecast_id,
        trim(variant_id) as variant_id,
        trim(warehouse_id) as warehouse_id,
        forecast_date,
        trim(forecast_period) as forecast_period,
        forecasted_demand,
        lower_bound,
        upper_bound,
        confidence_level,
        trim(forecast_model) as forecast_model,
        generated_at
    from source
)

select * from renamed
