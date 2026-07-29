{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.RETURNS

with source as (
    select * from "ORDERS"."RETURNS"
),

renamed as (
    select
        trim(return_id) as return_id,
        trim(return_number) as return_number,
        trim(order_id) as order_id,
        trim(customer_id) as customer_id,
        trim(status) as status,
        trim(return_type) as return_type,
        trim(refund_method) as refund_method,
        refund_amount,
        requested_at,
        received_at,
        processed_at,
        trim(notes) as notes,
        created_at,
        updated_at
    from source
)

select * from renamed
