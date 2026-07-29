{%snapshot scd_suppliers%}

{{
    config(
        target_schema='snapshots',
        unique_key='supplier_id',
        strategy='timestamp',
        updated_at='updated_at',
    )
}}

select * from {{ source('procurement', 'SUPPLIERS') }}

{%endsnapshot%}
