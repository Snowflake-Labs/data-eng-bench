{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.CAMPAIGN_RESPONSES
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.CAMPAIGN_RESPONSES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per campaign responses
 */

with source as (

    select * from {{ source('sfdc', 'CAMPAIGN_RESPONSES') }}

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
