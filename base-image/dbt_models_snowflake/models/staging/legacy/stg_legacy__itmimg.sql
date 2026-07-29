{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.ITMIMG
 *
 * Entity Type: table
 * Source: LEGACY - RAW_LEGACY.ITMIMG
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per itmimg
 */

with source as (

    select * from {{ source('legacy', 'ITMIMG') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        image_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(product_id) as product_id,
        trim(variant_id) as variant_id,
        trim(image_url) as image_url,
        trim(thumbnail_url) as thumbnail_url,
        trim(alt_text) as alt_text,
        trim(image_type) as image_type, sort_order as sort_order,
        width as width,
        height as height,
        file_size_kb as file_size_kb,
        is_primary as is_primary,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,

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
