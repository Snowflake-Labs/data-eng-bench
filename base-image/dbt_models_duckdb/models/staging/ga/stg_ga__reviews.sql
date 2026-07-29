{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.REVIEWS
 *
 * Entity Type: table
 * Source: GA - RAW_GA.REVIEWS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per reviews
 */

with source as (

    select * from {{ source('ga', 'REVIEWS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        review_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(product_id) as product_id,
        trim(variant_id) as variant_id,
        trim(customer_id) as customer_id,
        trim(order_id) as order_id,
        rating as rating,
        trim(review_title) as review_title,
        trim(review_text) as review_text,
        trim(pros) as pros,
        trim(cons) as cons,
        is_verified_purchase as is_verified_purchase,
        is_recommended as is_recommended,
        helpful_count as helpful_count,
        not_helpful_count as not_helpful_count,
        media_urls as media_urls,
        trim(status) as status,
        moderated_at as moderated_at,
        trim(moderated_by) as moderated_by,
        trim(rejection_reason) as rejection_reason,
        trim(review_source) as review_source,
        trim(reviewer_display_name) as reviewer_display_name,
        submitted_at as submitted_at,
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
