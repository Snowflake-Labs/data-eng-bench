{{
    config(
        materialized='view',
        tags=['pos', 'staging']
    )
}}

/*
 * Staging model for RAW_POS.TENDERS
 *
 * Entity Type: table
 * Source: POS - RAW_POS.TENDERS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per tenders
 */

with source as (

    select * from {{ source('pos', 'TENDERS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        payment_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(order_id) as order_id,
        trim(payment_method_id) as payment_method_id,
        trim(payment_method) as payment_method,
        trim(amount) as amount,
        trim(currency_code) as currency_code,
        trim(status) as status,
        trim(transaction_id) as transaction_id,
        trim(authorization_code) as authorization_code,
        trim(card_last_four) as card_last_four,
        trim(card_type) as card_type,
        processed_at as processed_at,
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
