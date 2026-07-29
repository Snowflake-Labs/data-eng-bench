{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.BSET
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.BSET
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per bset
 */

with source as (

    select * from {{ source('sap', 'BSET') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        tax_transaction_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(order_id) as order_id,
        trim(invoice_id) as invoice_id,
        trim(tax_rate_id) as tax_rate_id,
        trim(taxable_amount) as taxable_amount,
        trim(tax_amount) as tax_amount,
        tax_date as tax_date,
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
