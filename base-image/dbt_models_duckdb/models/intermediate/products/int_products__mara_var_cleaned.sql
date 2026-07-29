{{
    config(
        materialized='view',
        tags=['intermediate', 'products']
    )
}}

/*
    Intermediate model: int_products__mara_var_cleaned
    Domain: products

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_sap__mara_var') }}

),

cleaned AS (

    SELECT
        variant_id,
        product_id,
        sku,
        variant_name,
        variant_description,
        barcode,
        barcode_type,
        gtin,
        mpn,
        weight,
        weight_uom,
        length,
        width,
        height,
        dimension_uom,
        cost_price,
        compare_at_price,
        requires_shipping,
        is_taxable,
        inventory_policy,
        fulfillment_service,
        image_url,
        sort_order,
        is_default,
        is_active,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
