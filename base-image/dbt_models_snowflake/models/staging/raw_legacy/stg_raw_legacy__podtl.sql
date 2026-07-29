with source as (
    select * from {{ source('raw_legacy', 'podtl') }}
),

renamed as (
    select
        po_line_id as po_line_id,
        po_id as po_id, line_number as line_number,
        variant_id as variant_id,
        sku as sku,
        quantity_ordered as quantity_ordered,
        quantity_received as quantity_received,
        unit_price as unit_price,
        line_total as line_total,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id, _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
