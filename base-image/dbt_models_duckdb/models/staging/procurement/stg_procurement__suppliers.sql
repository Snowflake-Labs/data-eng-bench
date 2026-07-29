{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIERS

with source as (
    select * from {{ source('procurement', 'SUPPLIERS') }}
),

renamed as (
    select
        trim(supplier_id) as supplier_id,
        trim(supplier_code) as supplier_code,
        trim(supplier_name) as supplier_name,
        trim(supplier_type) as supplier_type,
        trim(tax_id) as tax_id,
        trim(duns_number) as duns_number,
        trim(payment_terms) as payment_terms,
        trim(currency_code) as currency_code,
        lead_time_days,
        min_order_value,
        rating,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
