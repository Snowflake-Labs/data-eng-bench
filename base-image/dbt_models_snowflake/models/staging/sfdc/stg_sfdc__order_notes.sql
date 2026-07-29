{{
    config(
        materialized='view',
        tags=['sfdc', 'staging']
    )
}}

/*
 * Staging model for RAW_SFDC.ORDER_NOTES
 *
 * Entity Type: table
 * Source: SFDC - RAW_SFDC.ORDER_NOTES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per order notes
 */

with source as (

    select * from {{ source('sfdc', 'ORDER_NOTES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        note_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(order_id) as order_id,
        trim(note_type) as note_type,
        trim(note_text) as note_text,
        is_internal as is_internal,
        trim(created_by) as created_by,
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
