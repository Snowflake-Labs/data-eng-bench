with source as (
    select * from {{ source('raw_sap', 'bseg_hist') }}
),

renamed as (
    select
        transaction_id as transaction_id,
        transaction_number as transaction_number,
        account_id as account_id,
        period_id as period_id,
        transaction_date as transaction_date,
        debit_amount as debit_amount,
        credit_amount as credit_amount,
        description as description,
        reference_type as reference_type,
        reference_id as reference_id,
        created_by as created_by,
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
