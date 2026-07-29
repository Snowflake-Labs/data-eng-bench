{{
    config(
        materialized='view',
        tags=['wms', 'staging']
    )
}}

/*
 * Staging model for RAW_WMS.ADJUSTMENTS
 *
 * Entity Type: table
 * Source: WMS - RAW_WMS.ADJUSTMENTS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per adjustments
 */

with source as (

    select * from {{ source('wms', 'ADJUSTMENTS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        adjustment_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(adjustment_number) as adjustment_number,
        trim(warehouse_id) as warehouse_id,
        trim(adjustment_type) as adjustment_type,
        trim(status) as status,
        trim(total_lines) as total_lines,
        trim(total_quantity) as total_quantity,
        trim(total_value) as total_value,
        trim(reason_code) as reason_code,
        trim(notes) as notes,
        trim(requested_by) as requested_by,
        requested_at as requested_at,
        trim(approved_by) as approved_by,
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
