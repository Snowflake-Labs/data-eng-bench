{{
    config(
        materialized='table',
        tags=['dimension', 'forecasts', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_demand_forecasts') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['forecast_id']) }} AS forecasts_key,
        forecast_id AS forecasts_id,
        
        -- Attributes
        variant_id,
        warehouse_id,
        forecast_date,
        forecast_period,
        forecasted_demand,
        lower_bound,
        upper_bound,
        confidence_level,
        forecast_model,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE forecast_id IS NOT NULL
)

SELECT * FROM final
