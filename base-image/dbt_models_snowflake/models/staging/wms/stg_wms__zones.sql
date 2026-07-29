{{
    config(
        materialized='view',
        tags=['wms', 'staging']
    )
}}

/*
 * Staging model for RAW_WMS.ZONES
 *
 * Entity Type: table
 * Source: WMS - RAW_WMS.ZONES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per zones
 */

with source as (

    select * from {{ source('wms', 'ZONES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        zone_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(warehouse_id) as warehouse_id,
        trim(zone_code) as zone_code,
        trim(zone_name) as zone_name,
        trim(zone_type) as zone_type,
        trim(temperature_controlled) as temperature_controlled,
        min_temperature as min_temperature,
        max_temperature as max_temperature,
        capacity_units as capacity_units,
        sort_order as sort_order,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,

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
