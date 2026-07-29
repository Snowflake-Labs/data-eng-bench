{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.ADS_CAMPAIGNS
 *
 * Entity Type: table
 * Source: GA - RAW_GA.ADS_CAMPAIGNS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per ads campaigns
 */

with source as (

    select * from {{ source('ga', 'ADS_CAMPAIGNS') }}

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
