{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.FACT_SALES

with source as (
    select * from {{ source('analytics', 'FACT_SALES') }}
),

renamed as (
    select
        trim(sale_key) as sale_key,
        date_key,
        time_key,
        customer_key,
        product_key,
        employee_key,
        channel_key,
        geography_key,
        trim(order_id) as order_id,
        trim(order_line_id) as order_line_id,
        quantity,
        unit_price,
        discount_amount,
        tax_amount,
        total_amount,
        cost_amount,
        profit_amount
    from source
)

select * from renamed
