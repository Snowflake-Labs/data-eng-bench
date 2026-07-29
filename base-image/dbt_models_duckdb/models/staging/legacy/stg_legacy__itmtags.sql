{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.ITMTAGS
 *
 * Entity Type: table
 * Source: LEGACY - RAW_LEGACY.ITMTAGS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per itmtags
 */

with source as (

    select * from {{ source('legacy', 'ITMTAGS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        tag_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(product_id) as product_id,
        trim(tag_name) as tag_name,
        trim(tag_type) as tag_type,
        created_at as created_at,

        /*
         * Metadata Columns
         */
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash

    from source

)

select * from renamed
