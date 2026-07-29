{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CUSTOMER_PAYMENT_APPLICATIONS

with source as (
    select * from {{ source('finance', 'CUSTOMER_PAYMENT_APPLICATIONS') }}
),

renamed as (
    select
        trim(application_id) as application_id,
        trim(payment_id) as payment_id,
        trim(invoice_id) as invoice_id,
        amount_applied,
        applied_at
    from source
)

select * from renamed
