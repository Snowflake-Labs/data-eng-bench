with source as (
    select * from {{ source('raw_sap', 'pbim') }}
),

renamed as (
    select
        forecast_id as forecast_id,
        variant_id as variant_id,
        warehouse_id as warehouse_id,
        forecast_date as forecast_date,
        forecast_period as forecast_period,
        forecasted_demand as forecasted_demand,
        lower_bound as lower_bound,
        upper_bound as upper_bound,
        confidence_level as confidence_level,
        forecast_model as forecast_model,
        generated_at as generated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
