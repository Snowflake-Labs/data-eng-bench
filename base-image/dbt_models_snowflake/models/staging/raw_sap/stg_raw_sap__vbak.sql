with source as (
    select * from {{ source('raw_sap', 'vbak') }}
),

renamed as (
    select
        order_id as order_id,
        order_number as order_number,
        customer_id as customer_id,
        order_type as order_type,
        order_source as order_source,
        channel_id as channel_id,
        currency_code as currency_code,
        exchange_rate as exchange_rate,
        billing_address_id as billing_address_id,
        shipping_address_id as shipping_address_id,
        subtotal as subtotal,
        discount_total as discount_total,
        shipping_total as shipping_total,
        tax_total as tax_total,
        grand_total as grand_total,
        status as status,
        payment_status as payment_status,
        fulfillment_status as fulfillment_status,
        ordered_at as ordered_at,
        shipped_at as shipped_at,
        delivered_at as delivered_at,
        cancelled_at as cancelled_at,
        ip_address as ip_address,
        user_agent as user_agent,
        notes as notes,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
