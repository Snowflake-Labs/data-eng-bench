{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.EKKO
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.EKKO
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per ekko
 */

with source as (

    select * from {{ source('sap', 'EKKO') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        po_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(po_number) as po_number,
        trim(supplier_id) as supplier_id,
        trim(warehouse_id) as warehouse_id,
        trim(status) as status,
        trim(total_amount) as total_amount,
        trim(currency_code) as currency_code,
        expected_date as expected_date,
        ordered_at as ordered_at,
        trim(created_by) as created_by,
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
