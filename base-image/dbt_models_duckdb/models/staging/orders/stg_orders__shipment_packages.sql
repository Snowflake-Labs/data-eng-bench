{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.SHIPMENT_PACKAGES

with source as (
    select * from {{ source('orders', 'SHIPMENT_PACKAGES') }}
),

renamed as (
    select
        trim(package_id) as package_id,
        trim(shipment_id) as shipment_id,
        package_number,
        trim(tracking_number) as tracking_number,
        weight,
        length,
        width,
        height,
        created_at
    from source
)

select * from renamed
