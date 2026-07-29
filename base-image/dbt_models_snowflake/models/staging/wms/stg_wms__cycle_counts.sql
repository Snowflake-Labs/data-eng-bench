{{
    config(
        materialized='view',
        tags=['wms', 'staging']
    )
}}

/*
 * Staging model for RAW_WMS.CYCLE_COUNTS
 *
 * Entity Type: table
 * Source: WMS - RAW_WMS.CYCLE_COUNTS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per cycle counts
 */

with source as (

    select * from {{ source('wms', 'CYCLE_COUNTS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        count_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(count_number) as count_number,
        trim(warehouse_id) as warehouse_id,
        trim(count_type) as count_type,
        trim(status) as status,
        scheduled_date as scheduled_date,
        trim(total_locations) as total_locations,
        trim(total_skus) as total_skus,
        trim(total_units_counted) as total_units_counted,
        trim(total_variance_units) as total_variance_units,
        trim(total_variance_value) as total_variance_value,
        trim(created_by) as created_by,
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
