{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.PROMO_CODES
 *
 * Entity Type: lookup
 * Source: GA - RAW_GA.PROMO_CODES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per promo codes
 */

with source as (

    select * from {{ source('ga', 'PROMO_CODES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        coupon_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(coupon_code) as coupon_code,
        trim(promotion_id) as promotion_id,
        usage_limit as usage_limit,
        usage_count as usage_count,
        is_active as is_active,
        expires_at as expires_at,
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
