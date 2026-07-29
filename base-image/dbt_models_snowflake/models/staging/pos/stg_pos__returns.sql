{{
    config(
        materialized='view',
        tags=['pos', 'staging']
    )
}}

/*
 * Staging model for RAW_POS.RETURNS
 *
 * Entity Type: table
 * Source: POS - RAW_POS.RETURNS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per returns
 */

with source as (

    select * from {{ source('pos', 'RETURNS') }}

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
