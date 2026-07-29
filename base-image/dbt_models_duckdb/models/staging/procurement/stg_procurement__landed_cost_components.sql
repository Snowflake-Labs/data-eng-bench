{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.LANDED_COST_COMPONENTS

with source as (
    select * from {{ source('procurement', 'LANDED_COST_COMPONENTS') }}
),

renamed as (
    select
        trim(component_id) as component_id,
        trim(variant_id) as variant_id,
        trim(component_type) as component_type,
        amount,
        trim(currency_code) as currency_code,
        effective_from,
        created_at
    from source
)

select * from renamed
