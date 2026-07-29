{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.WISHLISTS
 *
 * Entity Type: table
 * Source: GA - RAW_GA.WISHLISTS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per wishlists
 */

with source as (

    select * from {{ source('ga', 'WISHLISTS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        wishlist_item_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(wishlist_id) as wishlist_id,
        trim(variant_id) as variant_id,
        added_at as added_at,
        trim(notes) as notes,
        priority as priority,

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
