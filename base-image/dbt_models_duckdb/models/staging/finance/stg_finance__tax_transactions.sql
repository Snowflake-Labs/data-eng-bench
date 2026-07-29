{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.TAX_TRANSACTIONS

with source as (
    select * from {{ source('finance', 'TAX_TRANSACTIONS') }}
),

renamed as (
    select
        trim(tax_transaction_id) as tax_transaction_id,
        trim(order_id) as order_id,
        trim(invoice_id) as invoice_id,
        trim(tax_rate_id) as tax_rate_id,
        taxable_amount,
        tax_amount,
        tax_date,
        created_at
    from source
)

select * from renamed
