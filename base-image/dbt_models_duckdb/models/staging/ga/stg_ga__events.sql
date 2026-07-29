{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.EVENTS
 *
 * Entity Type: table
 * Source: GA - RAW_GA.EVENTS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per events
 */

with source as (

    select * from {{ source('ga', 'EVENTS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        event_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(session_id) as session_id,
        trim(event_type) as event_type,
        trim(event_name) as event_name,
        trim(event_timestamp) as event_timestamp,
        trim(page_url) as page_url,
        trim(element_id) as element_id,
        trim(element_class) as element_class,
        trim(product_id) as product_id,
        trim(event_value) as event_value,
        event_data as event_data,
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
