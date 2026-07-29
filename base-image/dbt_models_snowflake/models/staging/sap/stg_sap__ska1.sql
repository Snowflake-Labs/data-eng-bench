{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.SKA1
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.SKA1
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per ska1
 */

with source as (

    select * from {{ source('sap', 'SKA1') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        _id,  -- Primary key

        /*
         * Metadata Columns
         */
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash

    from source

)

select * from renamed
