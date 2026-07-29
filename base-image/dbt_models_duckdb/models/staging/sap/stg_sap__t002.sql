{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.T002
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.T002
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per t002
 */

with source as (

    select * from {{ source('sap', 'T002') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        language_code,  -- Primary key

        /*
         * Business Columns
         */
        trim(language_name) as language_name,
        trim(native_name) as native_name,
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
