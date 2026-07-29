with source as (
    select * from {{ source('raw_sap', 'bset_hist') }}
),

renamed as (
    select
        tax_transaction_id as tax_transaction_id,
        order_id as order_id,
        invoice_id as invoice_id,
        tax_rate_id as tax_rate_id,
        taxable_amount as taxable_amount,
        tax_amount as tax_amount,
        tax_date as tax_date,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _archived_at as _archived_at
    from source
)

select * from renamed
