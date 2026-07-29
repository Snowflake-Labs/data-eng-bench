{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.EMAIL_SENDS
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.EMAIL_SENDS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per email sends
 */

with source as (

    select * from {{ source('sfdc', 'EMAIL_SENDS') }}

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
