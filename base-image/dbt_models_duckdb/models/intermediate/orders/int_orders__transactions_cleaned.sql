{{
    config(
        materialized='view',
        tags=['intermediate', 'orders']
    )
}}

/*
    Intermediate model: int_orders__transactions_cleaned
    Domain: orders

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_pos__transactions') }}

),

cleaned AS (

    SELECT
        order_id,
        order_number,
        customer_id,
        order_type,
        order_source,
        channel_id,
        currency_code,
        exchange_rate,
        billing_address_id,
        shipping_address_id,
        subtotal,
        discount_total,
        shipping_total,
        tax_total,
        grand_total,
        status,
        payment_status,
        fulfillment_status,
        ordered_at,
        shipped_at,
        delivered_at,
        cancelled_at,
        ip_address,
        user_agent,
        notes,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
