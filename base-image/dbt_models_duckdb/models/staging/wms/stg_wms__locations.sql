{{
    config(
        materialized='view',
        tags=['wms', 'staging']
    )
}}

/*
 * Staging model for RAW_WMS.LOCATIONS
 *
 * Entity Type: table
 * Source: WMS - RAW_WMS.LOCATIONS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per locations
 */

with source as (

    select * from {{ source('wms', 'LOCATIONS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        location_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(warehouse_id) as warehouse_id,
        trim(zone_id) as zone_id,
        trim(location_code) as location_code,
        trim(location_barcode) as location_barcode,
        trim(aisle) as aisle,
        trim(rack) as rack,
        trim(shelf) as shelf,
        trim(location_type) as location_type,
        is_pickable as is_pickable,
        is_receivable as is_receivable,
        max_weight as max_weight,
        pick_sequence as pick_sequence,
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
