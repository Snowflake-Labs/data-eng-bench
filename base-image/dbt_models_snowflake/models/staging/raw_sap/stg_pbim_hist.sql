{{
    config(
        materialized='view',
        unique_key='forecast_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'PBIM_HIST') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(FORECAST_ID) AS forecast_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        FORECAST_DATE AS forecast_date,
        TRIM(FORECAST_PERIOD) AS forecast_period,
        COALESCE(FORECASTED_DEMAND, 0) AS forecasted_demand,
        COALESCE(LOWER_BOUND, 0) AS lower_bound,
        COALESCE(UPPER_BOUND, 0) AS upper_bound,
        COALESCE(CONFIDENCE_LEVEL, 0) AS confidence_level,
        TRIM(FORECAST_MODEL) AS forecast_model,
        GENERATED_AT AS generated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE FORECAST_ID IS NOT NULL
)

SELECT * FROM renamed
