{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.CSKS
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.CSKS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per csks
 */

with source as (

    select * from {{ source('sap', 'CSKS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        cost_center_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(cost_center_code) as cost_center_code,
        trim(cost_center_name) as cost_center_name,
        trim(manager_id) as manager_id,
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
