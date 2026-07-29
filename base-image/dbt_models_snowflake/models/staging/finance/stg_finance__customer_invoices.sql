{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CUSTOMER_INVOICES

with source as (
    select * from {{ source('finance', 'CUSTOMER_INVOICES') }}
),

renamed as (
    select
        trim(invoice_id) as invoice_id,
        trim(invoice_number) as invoice_number,
        trim(order_id) as order_id,
        trim(customer_id) as customer_id,
        invoice_date,
        due_date,
        subtotal,
        tax_amount,
        total_amount,
        amount_paid,
        balance_due,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
