with source as (
    select * from {{ source('raw_legacy', 'pohdr') }}
),

renamed as (
    select
        po_id as po_id,
        po_number as po_number,
        supplier_id as supplier_id,
        warehouse_id as warehouse_id,
        status as status,
        total_amount as total_amount,
        currency_code as currency_code,
        expected_date as expected_date,
        ordered_at as ordered_at,
        created_by as created_by,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
