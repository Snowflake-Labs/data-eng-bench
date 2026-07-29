{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.SHIPMENTS

with source as (
    select * from "ORDERS"."SHIPMENTS"
),

renamed as (
    select
        trim(shipment_id) as shipment_id,
        trim(shipment_number) as shipment_number,
        trim(order_id) as order_id,
        trim(warehouse_id) as warehouse_id,
        trim(carrier_id) as carrier_id,
        trim(shipping_method_id) as shipping_method_id,
        trim(tracking_number) as tracking_number,
        trim(status) as status,
        shipped_at,
        delivered_at,
        shipping_cost,
        weight,
        created_at,
        updated_at
    from source
)

select * from renamed
