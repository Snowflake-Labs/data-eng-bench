{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.VBAK
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.VBAK
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per vbak
 */

with source as (

    select * from {{ source('sap', 'VBAK') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        order_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(order_number) as order_number,
        trim(customer_id) as customer_id,
        trim(order_type) as order_type,
        trim(order_source) as order_source,
        trim(channel_id) as channel_id,
        trim(currency_code) as currency_code,
        exchange_rate as exchange_rate,
        trim(billing_address_id) as billing_address_id,
        trim(shipping_address_id) as shipping_address_id,
        trim(subtotal) as subtotal,
        trim(discount_total) as discount_total,
        trim(shipping_total) as shipping_total,
        trim(tax_total) as tax_total,
        trim(grand_total) as grand_total,
        trim(status) as status,
        trim(payment_status) as payment_status,
        trim(fulfillment_status) as fulfillment_status,
        ordered_at as ordered_at,
        shipped_at as shipped_at,
        delivered_at as delivered_at,
        cancelled_at as cancelled_at,
        trim(ip_address) as ip_address,
        trim(user_agent) as user_agent,
        trim(notes) as notes,
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
