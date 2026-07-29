{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.FACT_INVENTORY

with source as (
    select * from {{ source('analytics', 'FACT_INVENTORY') }}
),

renamed as (
    select
        trim(inventory_key) as inventory_key,
        date_key,
        product_key,
        trim(warehouse_id) as warehouse_id,
        quantity_on_hand,
        quantity_available,
        quantity_reserved,
        quantity_incoming,
        unit_cost,
        total_value
    from source
)

select * from renamed
