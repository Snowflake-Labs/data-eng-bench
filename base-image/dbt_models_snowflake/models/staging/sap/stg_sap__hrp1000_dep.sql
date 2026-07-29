{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.HRP1000_DEP
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.HRP1000_DEP
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per hrp1000 dep
 */

with source as (

    select * from {{ source('sap', 'HRP1000_DEP') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        department_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(department_code) as department_code,
        trim(department_name) as department_name,
        trim(parent_department_id) as parent_department_id,
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
