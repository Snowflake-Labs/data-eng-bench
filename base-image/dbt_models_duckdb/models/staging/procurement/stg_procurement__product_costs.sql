{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PRODUCT_COSTS

with source as (
    select * from {{ source('procurement', 'PRODUCT_COSTS') }}
),

renamed as (
    select
        trim(cost_id) as cost_id,
        trim(variant_id) as variant_id,
        trim(supplier_id) as supplier_id,
        trim(cost_type) as cost_type,
        unit_cost,
        trim(currency_code) as currency_code,
        effective_from,
        effective_to,
        created_at
    from source
)

select * from renamed
