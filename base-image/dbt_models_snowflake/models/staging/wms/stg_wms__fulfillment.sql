{{
    config(
        materialized='view',
        tags=['wms', 'staging']
    )
}}

/*
 * Staging model for RAW_WMS.FULFILLMENT
 *
 * Entity Type: table
 * Source: WMS - RAW_WMS.FULFILLMENT
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per fulfillment
 */

with source as (

    select * from {{ source('wms', 'FULFILLMENT') }}

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
