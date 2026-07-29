{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.BRANDS
 *
 * Entity Type: table
 * Source: LEGACY - RAW_LEGACY.BRANDS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per brands
 */

with source as (

    select * from {{ source('legacy', 'BRANDS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        brand_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(brand_code) as brand_code,
        trim(brand_name) as brand_name,
        trim(brand_description) as brand_description,
        trim(brand_logo_url) as brand_logo_url,
        trim(brand_website) as brand_website,
        trim(parent_brand_id) as parent_brand_id,
        is_private_label as is_private_label,
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
