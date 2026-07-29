{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.CATSDB
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.CATSDB
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per catsdb
 */

with source as (

    select * from {{ source('sap', 'CATSDB') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        entry_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(employee_id) as employee_id,
        entry_date as entry_date,
        trim(clock_in) as clock_in,
        trim(clock_out) as clock_out,
        break_minutes as break_minutes,
        hours_worked as hours_worked,
        trim(entry_type) as entry_type,
        trim(status) as status,
        created_at as created_at,

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
