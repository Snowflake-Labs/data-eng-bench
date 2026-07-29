with source as (
    select * from {{ source('raw_sap', 'mara_var_hist') }}
),

renamed as (
    select
        variant_id as variant_id,
        product_id as product_id,
        sku as sku,
        variant_name as variant_name,
        variant_description as variant_description,
        barcode as barcode,
        barcode_type as barcode_type,
        gtin as gtin,
        mpn as mpn,
        weight as weight,
        weight_uom as weight_uom,
        length as length,
        width as width,
        height as height,
        dimension_uom as dimension_uom,
        cost_price as cost_price,
        compare_at_price as compare_at_price,
        requires_shipping as requires_shipping,
        is_taxable as is_taxable,
        inventory_policy as inventory_policy,
        fulfillment_service as fulfillment_service,
        image_url as image_url,
        sort_order as sort_order,
        is_default as is_default,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _archived_at as _archived_at
    from source
)

select * from renamed
