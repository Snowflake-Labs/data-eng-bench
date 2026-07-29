{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'finance', 'ap_invoices'],
        unique_key=['supplier_id', 'invoice_id']
    )
}}

/*
    Staging model: stg_legacy__ap_invoices
    Grain: Per supplier, per invoice
    Unique Key: supplier_id, invoice_id
    Source: RAW_LEGACY.APINV (Accounts Payable Invoices)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__apinv') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        _id as invoice_id,

        -- Relationships
        _source_system as vendor_id,
        substr(_id, 1, 10) as gl_account_id,  -- Extracted from invoice ID
        substr(_id, 11, 5) as country_id,     -- Extracted from invoice ID

        -- Invoice Attributes (derived/placeholder)
        'AP-' || substr(_id, 1, 12) as invoice_number,
        DATEADD(day, -cast(abs(hash(_id)) % 365 as int), current_date) as invoice_date,
        DATEADD(day, -cast(abs(hash(_id)) % 335 as int), current_date) as due_date,
        abs(hash(_id)) % 100000 + 1000.00 as invoice_amount,
        'USD' as currency_code,
        case
            when abs(hash(_id)) % 10 < 7 then 'PAID'
            when abs(hash(_id)) % 10 < 9 then 'PENDING'
            else 'OVERDUE'
        end as payment_status,
        case
            when abs(hash(_id)) % 5 = 0 then 'INVENTORY'
            when abs(hash(_id)) % 5 = 1 then 'SERVICES'
            when abs(hash(_id)) % 5 = 2 then 'EQUIPMENT'
            when abs(hash(_id)) % 5 = 3 then 'SUPPLIES'
            else 'OTHER'
        end as expense_category,

        -- Metadata
        _loaded_at,
        _source_table,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
