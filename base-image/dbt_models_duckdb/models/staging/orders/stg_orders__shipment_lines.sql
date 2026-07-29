{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.SHIPMENT_LINES

with source as (
    select * from {{ source('orders', 'SHIPMENT_LINES') }}
),

renamed as (
    select
        trim(shipment_line_id) as shipment_line_id,
        trim(shipment_id) as shipment_id,
        trim(order_line_id) as order_line_id,
        quantity_shipped,
        created_at
    from source
)

select * from renamed
