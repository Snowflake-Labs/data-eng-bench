{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.T006
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.T006
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per t006
 */

with source as (

    select * from {{ source('sap', 'T006') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        uom_code,  -- Primary key

        /*
         * Business Columns
         */
        trim(uom_name) as uom_name,
        trim(uom_type) as uom_type,
        trim(base_uom_code) as base_uom_code,
        conversion_factor as conversion_factor,
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
