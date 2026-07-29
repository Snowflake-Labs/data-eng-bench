with source as (
    select * from {{ source('raw_pos', 'trans_lines_hist') }}
),

renamed as (
    select
        order_line_id as order_line_id,
        order_id as order_id,
        line_number as line_number,
        variant_id as variant_id,
        product_id as product_id,
        sku as sku,
        product_name as product_name,
        variant_name as variant_name,
        quantity_ordered as quantity_ordered,
        quantity_shipped as quantity_shipped,
        quantity_returned as quantity_returned,
        unit_price as unit_price,
        discount_amount as discount_amount,
        tax_amount as tax_amount,
        line_total as line_total,
        status as status,
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
