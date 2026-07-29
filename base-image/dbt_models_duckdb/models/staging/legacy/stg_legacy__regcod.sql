{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.REGCOD
 *
 * Entity Type: lookup
 * Source: LEGACY - RAW_LEGACY.REGCOD
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per regcod
 */

with source as (

    select * from {{ source('legacy', 'REGCOD') }}

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
