{%snapshot scd_prices%}

{{
    config(
        target_schema='snapshots',
        unique_key='price_id',
        strategy='timestamp',
        updated_at='updated_at',
    )
}}

select * from {{ source('product', 'PRODUCT_PRICES') }}

{%endsnapshot%}
