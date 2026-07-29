{{
    config(
        materialized='view',
        tags=['pos', 'staging']
    )
}}

/*
 * Staging model for RAW_POS.TRANS_LINES
 *
 * Entity Type: fact
 * Source: POS - RAW_POS.TRANS_LINES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per trans lines
 */

with source as (

    select * from {{ source('pos', 'TRANS_LINES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        order_line_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(order_id) as order_id,
        line_number as line_number,
        trim(variant_id) as variant_id,
        trim(product_id) as product_id,
        trim(sku) as sku,
        trim(product_name) as product_name,
        trim(variant_name) as variant_name,
        quantity_ordered as quantity_ordered,
        quantity_shipped as quantity_shipped,
        quantity_returned as quantity_returned,
        trim(unit_price) as unit_price,
        trim(discount_amount) as discount_amount,
        trim(tax_amount) as tax_amount,
        trim(line_total) as line_total,
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
