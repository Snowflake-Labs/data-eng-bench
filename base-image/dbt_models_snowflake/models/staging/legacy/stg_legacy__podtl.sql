{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.PODTL
 *
 * Entity Type: table
 * Source: LEGACY - RAW_LEGACY.PODTL
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per podtl
 */

with source as (

    select * from {{ source('legacy', 'PODTL') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        po_line_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(po_id) as po_id, line_number as line_number,
        trim(variant_id) as variant_id,
        trim(sku) as sku, quantity_ordered as quantity_ordered,
        quantity_received as quantity_received,
        trim(unit_price) as unit_price,
        trim(line_total) as line_total,
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
