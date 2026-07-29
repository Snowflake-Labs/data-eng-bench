{% snapshot snap_prices %}

{{
    config(
        target_schema='snapshots',
        unique_key='price_id',
        strategy='check',
        check_cols=['unit_price', 'currency_code', 'effective_date'],
        enabled=false
    )
}}

SELECT * FROM {{ ref('int_prices__standardized') }}

{% endsnapshot %}
