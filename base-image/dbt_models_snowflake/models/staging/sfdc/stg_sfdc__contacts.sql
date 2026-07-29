{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.CONTACTS
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.CONTACTS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per contacts
 */

with source as (

    select * from {{ source('sfdc', 'CONTACTS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        contact_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(customer_id) as customer_id,
        trim(contact_type) as contact_type,
        trim(contact_subtype) as contact_subtype,
        trim(contact_value) as contact_value,
        is_primary as is_primary,
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
