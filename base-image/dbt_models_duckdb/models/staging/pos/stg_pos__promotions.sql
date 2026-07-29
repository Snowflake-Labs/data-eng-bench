{{
    config(
        materialized='view',
        tags=['pos', 'staging']
    )
}}

/*
 * Staging model for RAW_POS.PROMOTIONS
 *
 * Entity Type: table
 * Source: POS - RAW_POS.PROMOTIONS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per promotions
 */

with source as (

    select * from {{ source('pos', 'PROMOTIONS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        promotion_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(promotion_code) as promotion_code,
        trim(promotion_name) as promotion_name,
        trim(promotion_type) as promotion_type,
        trim(discount_type) as discount_type,
        trim(discount_value) as discount_value,
        min_purchase as min_purchase,
        max_discount as max_discount,
        start_date as start_date,
        end_date as end_date,
        is_active as is_active,
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
