{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_VARIANTS

with source as (
    select * from {{ source('product', 'PRODUCT_VARIANTS') }}
),

renamed as (
    select
        trim(variant_id) as variant_id,
        trim(product_id) as product_id,
        trim(sku) as sku,
        trim(variant_name) as variant_name,
        trim(variant_description) as variant_description,
        trim(barcode) as barcode,
        trim(barcode_type) as barcode_type,
        trim(gtin) as gtin,
        trim(mpn) as mpn,
        weight,
        trim(weight_uom) as weight_uom,
        length,
        width,
        height,
        trim(dimension_uom) as dimension_uom,
        cost_price,
        compare_at_price,
        requires_shipping,
        is_taxable,
        trim(inventory_policy) as inventory_policy,
        trim(fulfillment_service) as fulfillment_service,
        trim(image_url) as image_url,
        sort_order,
        is_default,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
