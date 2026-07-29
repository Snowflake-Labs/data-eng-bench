{%snapshot scd_customers%}

{{
    config(
        target_schema='snapshots',
        unique_key='customer_id',
        strategy='timestamp',
        updated_at='updated_at',
    )
}}

select * from {{ source('customer', 'CUSTOMERS') }}

{%endsnapshot%}
