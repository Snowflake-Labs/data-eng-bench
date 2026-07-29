{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.DEVICES
 *
 * Entity Type: table
 * Source: GA - RAW_GA.DEVICES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per devices
 */

with source as (

    select * from {{ source('ga', 'DEVICES') }}

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
