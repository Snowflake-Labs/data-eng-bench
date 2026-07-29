{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.MIGO
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.MIGO
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per migo
 */

with source as (

    select * from {{ source('sap', 'MIGO') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        transfer_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(transfer_number) as transfer_number,
        trim(transfer_type) as transfer_type,
        trim(source_type) as source_type,
        trim(source_warehouse_id) as source_warehouse_id,
        trim(source_store_id) as source_store_id,
        trim(dest_type) as dest_type,
        trim(dest_warehouse_id) as dest_warehouse_id,
        trim(dest_store_id) as dest_store_id,
        trim(status) as status,
        trim(priority) as priority,
        trim(total_lines) as total_lines,
        trim(total_quantity) as total_quantity,
        trim(total_value) as total_value,
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
