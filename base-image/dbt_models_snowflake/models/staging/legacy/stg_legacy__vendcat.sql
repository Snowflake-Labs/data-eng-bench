{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.VENDCAT
 *
 * Entity Type: table
 * Source: LEGACY - RAW_LEGACY.VENDCAT
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per vendcat
 */

with source as (

    select * from {{ source('legacy', 'VENDCAT') }}

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
        -- _id (removed duplicate)
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash

    from source

)

select * from renamed
