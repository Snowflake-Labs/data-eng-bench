{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.SHIPMENT_TRACKING

with source as (
    select * from {{ source('orders', 'SHIPMENT_TRACKING') }}
),

renamed as (
    select
        trim(tracking_id) as tracking_id,
        trim(shipment_id) as shipment_id,
        trim(status) as status,
        trim(location) as location,
        trim(description) as description,
        tracked_at,
        created_at
    from source
)

select * from renamed
