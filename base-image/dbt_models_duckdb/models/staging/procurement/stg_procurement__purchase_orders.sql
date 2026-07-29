{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PURCHASE_ORDERS

with source as (
    select * from {{ source('procurement', 'PURCHASE_ORDERS') }}
),

renamed as (
    select
        trim(po_id) as po_id,
        trim(po_number) as po_number,
        trim(supplier_id) as supplier_id,
        trim(warehouse_id) as warehouse_id,
        trim(status) as status,
        total_amount,
        trim(currency_code) as currency_code,
        expected_date,
        ordered_at,
        trim(created_by) as created_by,
        created_at,
        updated_at
    from source
)

select * from renamed
