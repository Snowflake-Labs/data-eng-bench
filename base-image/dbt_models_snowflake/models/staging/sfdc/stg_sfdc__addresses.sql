{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.ADDRESSES
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.ADDRESSES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per addresses
 */

with source as (

    select * from {{ source('sfdc', 'ADDRESSES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        address_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(customer_id) as customer_id,
        trim(address_type) as address_type,
        trim(address_label) as address_label,
        is_default_billing as is_default_billing,
        is_default_shipping as is_default_shipping,
        trim(recipient_name) as recipient_name,
        trim(company_name) as company_name,
        trim(address_line_1) as address_line_1,
        trim(address_line_2) as address_line_2,
        trim(address_line_3) as address_line_3,
        trim(city) as city,
        trim(state_province) as state_province,
        trim(postal_code) as postal_code,
        trim(country_code) as country_code,
        trim(phone) as phone,
        trim(delivery_instructions) as delivery_instructions, latitude as latitude,
        longitude as longitude,
        is_verified as is_verified,
        verified_at as verified_at,
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
