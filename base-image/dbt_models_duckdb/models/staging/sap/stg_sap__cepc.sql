{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.CEPC
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.CEPC
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per cepc
 */

with source as (

    select * from {{ source('sap', 'CEPC') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        profit_center_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(profit_center_code) as profit_center_code,
        trim(profit_center_name) as profit_center_name,
        is_active as is_active,
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
