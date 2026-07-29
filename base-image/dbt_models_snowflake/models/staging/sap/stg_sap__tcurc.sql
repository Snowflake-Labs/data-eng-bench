{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.TCURC
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.TCURC
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per tcurc
 */

with source as (

    select * from {{ source('sap', 'TCURC') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        currency_code,  -- Primary key

        /*
         * Business Columns
         */
        trim(currency_name) as currency_name,
        trim(currency_symbol) as currency_symbol,
        decimal_places as decimal_places,
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
