{{
    config(
        materialized='view',
        tags=['payments', 'staging']
    )
}}

/*
 * Staging model for RAW_PAYMENTS.CHARGES
 *
 * Entity Type: table
 * Source: PAYMENTS - RAW_PAYMENTS.CHARGES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per charges
 */

with source as (

    select * from {{ source('payments', 'CHARGES') }}

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
