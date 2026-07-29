{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.ACCOUNT_TIERS
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.ACCOUNT_TIERS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per account tiers
 */

with source as (

    select * from {{ source('sfdc', 'ACCOUNT_TIERS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        tier_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(tier_code) as tier_code,
        trim(tier_name) as tier_name,
        tier_level as tier_level,
        min_points_required as min_points_required,
        min_spend_required as min_spend_required,
        points_multiplier as points_multiplier,
        discount_percentage as discount_percentage,
        trim(free_shipping) as free_shipping,
        trim(benefits_description) as benefits_description,
        trim(tier_color) as tier_color,
        trim(tier_icon) as tier_icon,
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
