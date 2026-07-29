{{
    config(
        materialized='view',
        tags=['pos', 'staging']
    )
}}

/*
 * Staging model for RAW_POS.COUPON_USAGE
 *
 * Entity Type: table
 * Source: POS - RAW_POS.COUPON_USAGE
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per coupon usage
 */

with source as (

    select * from {{ source('pos', 'COUPON_USAGE') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        redemption_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(coupon_id) as coupon_id,
        trim(order_id) as order_id,
        trim(customer_id) as customer_id,
        trim(discount_amount) as discount_amount,
        redeemed_at as redeemed_at,

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
