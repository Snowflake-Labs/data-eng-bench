{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PURCHASE_CONTRACTS

with source as (
    select * from {{ source('procurement', 'PURCHASE_CONTRACTS') }}
),

renamed as (
    select
        trim(contract_id) as contract_id,
        trim(contract_number) as contract_number,
        trim(supplier_id) as supplier_id,
        trim(contract_type) as contract_type,
        start_date,
        end_date,
        total_value,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
