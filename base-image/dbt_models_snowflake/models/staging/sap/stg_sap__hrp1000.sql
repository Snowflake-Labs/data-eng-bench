{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.HRP1000
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.HRP1000
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per hrp1000
 */

with source as (

    select * from {{ source('sap', 'HRP1000') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        assignment_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(employee_id) as employee_id,
        trim(position_id) as position_id,
        start_date as start_date,
        end_date as end_date,
        is_primary as is_primary,
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
