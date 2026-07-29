{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.STSCOD
 *
 * Entity Type: lookup
 * Source: LEGACY - RAW_LEGACY.STSCOD
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per stscod
 */

with source as (

    select * from {{ source('legacy', 'STSCOD') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        status_code_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(entity_type) as entity_type,
        trim(status_code) as status_code,
        trim(status_name) as status_name,
        trim(status_description) as status_description,
        display_order as display_order,
        is_terminal as is_terminal,
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
