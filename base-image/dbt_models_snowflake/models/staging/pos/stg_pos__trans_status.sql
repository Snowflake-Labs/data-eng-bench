{{
    config(
        materialized='view',
        tags=['pos', 'staging']
    )
}}

/*
 * Staging model for RAW_POS.TRANS_STATUS
 *
 * Entity Type: fact
 * Source: POS - RAW_POS.TRANS_STATUS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per trans status
 */

with source as (

    select * from {{ source('pos', 'TRANS_STATUS') }}

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
