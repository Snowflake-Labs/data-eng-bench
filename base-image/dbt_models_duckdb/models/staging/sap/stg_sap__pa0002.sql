{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.PA0002
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.PA0002
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per pa0002
 */

with source as (

    select * from {{ source('sap', 'PA0002') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        employee_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(employee_number) as employee_number,
        trim(first_name) as first_name,
        trim(last_name) as last_name,
        trim(email) as email,
        trim(phone) as phone,
        hire_date as hire_date,
        termination_date as termination_date,
        trim(manager_id) as manager_id,
        trim(department_id) as department_id,
        trim(position_id) as position_id,
        trim(employment_type) as employment_type,
        trim(status) as status,
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
