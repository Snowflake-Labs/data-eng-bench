{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.PBIM
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.PBIM
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per pbim
 */

with source as (

    select * from {{ source('sap', 'PBIM') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        forecast_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(variant_id) as variant_id,
        trim(warehouse_id) as warehouse_id,
        forecast_date as forecast_date,
        trim(forecast_period) as forecast_period,
        forecasted_demand as forecasted_demand,
        lower_bound as lower_bound,
        upper_bound as upper_bound,
        confidence_level as confidence_level,
        trim(forecast_model) as forecast_model,
        generated_at as generated_at,

        /*
         * Metadata Columns
         */
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash

    from source

)

select * from renamed
