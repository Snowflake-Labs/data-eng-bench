{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIER_INVOICES

with source as (
    select * from {{ source('procurement', 'SUPPLIER_INVOICES') }}
),

renamed as (
    select
        trim(invoice_id) as invoice_id,
        trim(invoice_number) as invoice_number,
        trim(supplier_id) as supplier_id,
        trim(po_id) as po_id,
        invoice_date,
        due_date,
        total_amount,
        trim(currency_code) as currency_code,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
