{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.PREFERENCES
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.PREFERENCES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per preferences
 */

with source as (

    select * from {{ source('sfdc', 'PREFERENCES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        preference_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(customer_id) as customer_id,
        trim(preference_category) as preference_category,
        trim(preference_key) as preference_key,
        trim(preference_value) as preference_value,
        is_opted_in as is_opted_in,
        trim(effective_from) as effective_from,
        trim(effective_to) as effective_to,
        trim(source) as source,
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
