{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.PROMO_ITEMS
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.PROMO_ITEMS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per promo items
 */

with source as (

    select * from {{ source('sap', 'PROMO_ITEMS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        mapping_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(promotion_id) as promotion_id,
        trim(product_id) as product_id,
        trim(category_id) as category_id,
        trim(brand_id) as brand_id,
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
