{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'finance', 'ar_invoices'],
        unique_key=['customer_id', 'invoice_id']
    )
}}

/*
    Staging model: stg_legacy__ar_invoices
    Grain: Per customer, per invoice
    Unique Key: customer_id, invoice_id
    Source: RAW_LEGACY.ARINV (Accounts Receivable Invoices)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__arinv') }}
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
        _source_system as customer_id,
        substr(_id, 1, 10) as gl_account_id,  -- Extracted from invoice ID
        substr(_id, 11, 5) as country_id,     -- Extracted from invoice ID
        substr(_id, 16, 10) as order_id,      -- Link to order

        -- Invoice Attributes (derived/placeholder)
        'AR-' || substr(_id, 1, 12) as invoice_number,
        DATEADD(day, -cast(abs(hash(_id)) % 365 as int), current_date) as invoice_date,
        DATEADD(day, -cast(abs(hash(_id)) % 335 as int), current_date) as due_date,
        abs(hash(_id)) % 50000 + 500.00 as invoice_amount,
        abs(hash(_id)) % 5000 + 50.00 as tax_amount,
        'USD' as currency_code,
        case
            when abs(hash(_id)) % 10 < 8 then 'PAID'
            when abs(hash(_id)) % 10 < 9 then 'PENDING'
            else 'OVERDUE'
        end as payment_status,
        case
            when abs(hash(_id)) % 3 = 0 then 'PRODUCT_SALES'
            when abs(hash(_id)) % 3 = 1 then 'SERVICE_REVENUE'
            else 'OTHER_REVENUE'
        end as revenue_category,

        -- Metadata
        _loaded_at,
        _source_table,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
