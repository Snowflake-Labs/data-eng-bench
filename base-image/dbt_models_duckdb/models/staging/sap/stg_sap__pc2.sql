{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.PC2
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.PC2
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per pc2
 */

with source as (

    select * from {{ source('sap', 'PC2') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        payroll_run_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(payroll_period) as payroll_period,
        trim(period_start) as period_start,
        trim(period_end) as period_end,
        pay_date as pay_date,
        trim(status) as status,
        trim(total_gross) as total_gross,
        trim(total_net) as total_net,
        employee_count as employee_count,
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
