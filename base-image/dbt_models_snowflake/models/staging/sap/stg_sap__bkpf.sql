{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.BKPF
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.BKPF
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per bkpf
 */

with source as (

    select * from {{ source('sap', 'BKPF') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        transaction_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(transaction_number) as transaction_number,
        trim(account_id) as account_id,
        trim(period_id) as period_id,
        transaction_date as transaction_date,
        trim(debit_amount) as debit_amount,
        trim(credit_amount) as credit_amount,
        trim(description) as description,
        trim(reference_type) as reference_type,
        trim(reference_id) as reference_id,
        trim(created_by) as created_by,
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
