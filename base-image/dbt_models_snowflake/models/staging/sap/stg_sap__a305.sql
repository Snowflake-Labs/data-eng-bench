{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.A305
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.A305
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per a305
 */

with source as (

    select * from {{ source('sap', 'A305') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        price_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(variant_id) as variant_id,
        trim(price_type) as price_type,
        trim(currency_code) as currency_code,
        trim(price_amount) as price_amount,
        trim(compare_at_price) as compare_at_price,
        trim(cost_price) as cost_price,
        min_qty as min_qty,
        max_qty as max_qty,
        trim(customer_tier_id) as customer_tier_id,
        trim(channel_id) as channel_id,
        trim(effective_from) as effective_from,
        trim(effective_to) as effective_to,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        trim(created_by) as created_by,

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
