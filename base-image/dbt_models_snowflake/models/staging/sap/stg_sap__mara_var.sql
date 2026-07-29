{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.MARA_VAR
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.MARA_VAR
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per mara var
 */

with source as (

    select * from {{ source('sap', 'MARA_VAR') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        variant_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(product_id) as product_id,
        trim(sku) as sku,
        trim(variant_name) as variant_name,
        trim(variant_description) as variant_description,
        trim(barcode) as barcode,
        trim(barcode_type) as barcode_type,
        trim(gtin) as gtin,
        trim(mpn) as mpn, weight as weight,
        trim(weight_uom) as weight_uom, length as length,
        width as width,
        height as height,
        trim(dimension_uom) as dimension_uom,
        trim(cost_price) as cost_price,
        trim(compare_at_price) as compare_at_price,
        trim(requires_shipping) as requires_shipping,
        is_taxable as is_taxable,
        trim(inventory_policy) as inventory_policy,
        trim(fulfillment_service) as fulfillment_service,
        trim(image_url) as image_url, sort_order as sort_order,
        is_default as is_default,
        is_active as is_active,
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
