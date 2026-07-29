{% snapshot snap_products %}

{{
    config(
        target_schema='snapshots',
        unique_key='product_id',
        strategy='timestamp',
        updated_at='updated_at',
        invalidate_hard_deletes=True
    )
}}

SELECT * FROM {{ ref('dim_products') }}

{% endsnapshot %}
